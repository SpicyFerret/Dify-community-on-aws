# Dify-community-on-aws

Infrastructure as code para rodar o [Dify Community](https://docs.dify.ai/en/self-host/quick-start/docker-compose)
em uma unica EC2 na AWS, provisionada via **OpenTofu** e **GitHub Actions**.

## Arquitetura

- **EC2 `t3.medium`** (Amazon Linux 2023) em VPC dedicada, subnet publica usada apenas
  para egress (sem NAT Gateway, sem Elastic IP).
- **Launch template** com user-data que instala **Docker** e sobe o **cloudflared** como
  container, conectando a um **Cloudflare Tunnel** gerenciado pelo OpenTofu.
- **Sem portas abertas para a internet.** O acesso publico ao Dify chega pelo tunnel
  (HTTP -> `localhost:80`); o acesso administrativo e' por **SSH via Cloudflare WARP**
  (warp-routing -> IP privado da EC2).
- **EventBridge Scheduler** liga a maquina as **08h** e desliga as **18h**, **Seg-Sex**
  (`America/Sao_Paulo`), via chamada direta `ec2:Start/StopInstances` (sem Lambda).
- **Bucket S3** para o storage de arquivos do Dify (`STORAGE_TYPE=s3` +
  `S3_USE_AWS_MANAGED_IAM=true`, acesso pela IAM role da instancia, sem chaves).
- **State remoto** em S3 com lock em DynamoDB.

> Escopo deste repo (camada `infra/`): rede + EC2 + Docker/cloudflared + bucket S3 + tunnel
> + agendamento + pipeline. O deploy do `docker-compose` do Dify e' a camada `app/`.

## Estrutura

```
infra/                 # OpenTofu da infraestrutura
  versions.tf          # versoes + backend S3
  providers.tf         # providers aws + cloudflare
  variables.tf         # variaveis de entrada
  network.tf           # VPC, subnet, IGW, route table, security group
  compute.tf           # AMI, key pair, IAM role, launch template, instancia
  user_data.sh.tftpl   # user-data (docker + cloudflared via container)
  s3.tf                # bucket de storage do Dify + policy IAM
  cloudflare.tf        # tunnel, config (ingress/warp), rota privada, DNS
  schedule.tf          # EventBridge Scheduler start/stop
  outputs.tf
  iam/                 # exemplos de policy/trust do CI
app/
  deploy.sh            # deploy do Dify na EC2 (rodado via SSM, idempotente)
.github/workflows/infra.yml   # pipeline infra (fmt, tflint, validate, plan, apply/destroy)
.github/workflows/app.yml     # pipeline app (deploy do Dify via SSM)
.env.infra.example     # variaveis da infra
.env.app.example       # variaveis do app (referencia; injetadas pelo deploy.sh)
```

## Pre-requisitos

- Conta AWS + credenciais com permissao para criar VPC/EC2/IAM/S3/Scheduler.
- Conta Cloudflare: `account_id`, `zone_id` e um **API token** com permissoes
  `Account > Cloudflare Tunnel: Edit` e `Zone > DNS: Edit`.
- OpenTofu >= 1.8 (CLI `tofu`), e (para validar localmente) [tflint](https://github.com/terraform-linters/tflint).

## Bootstrap do backend

O backend e' **chumbado e deterministico** (nao precisa de secret): o nome do bucket de
state e' montado em runtime como **`<prefixo>-<accountId>-<region>`** (Account-Regional
namespace). Os valores fixos ficam no `env` do workflow:

```
STATE_BUCKET_PREFIX = dify-tfstate     # => dify-tfstate-<accountId>-<region>
STATE_KEY           = infra/terraform.tfstate
STATE_LOCK_TABLE    = dify-tflock
```

**No CI o bootstrap e' automatico**: o passo `Bootstrap remote state (S3 + DynamoDB)`
cria o bucket (versionado, encriptado, sem acesso publico) e a tabela de lock de forma
**idempotente** antes do init.

Para uso **local** (antes de qualquer rodada do pipeline), crie o backend manualmente
com o mesmo nome deterministico:

```bash
AWS_REGION=us-east-1
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="dify-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
LOCK_TABLE=dify-tflock

aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name "$LOCK_TABLE" --region "$AWS_REGION" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

> `us-east-1` dispensa `--create-bucket-configuration`; em outras regioes adicione
> `--create-bucket-configuration LocationConstraint=$AWS_REGION`.

## Uso local

```bash
cp .env.infra.example .env.infra      # preencha os valores
set -a && source .env.infra && set +a

# AWS_ACCOUNT_ID vem do .env.infra; ou: AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="dify-tfstate-${AWS_ACCOUNT_ID}-${AWS_REGION}"

tofu -chdir=infra init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=infra/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=dify-tflock"

tofu -chdir=infra plan
tofu -chdir=infra apply
```

## CI/CD (GitHub Actions)

Workflow `Deploy Infra` (`.github/workflows/infra.yml`):

- Em todo evento: garante o backend (cria bucket S3 + tabela DynamoDB se faltarem, idempotente).
- **Pull request** -> roda `fmt`, `tflint`, `validate`, `plan`.
- **Push na branch `infra`** -> aplica (`apply`).
- **`workflow_dispatch` com `destroy=true`** -> destroi a infra.

Variavel (repository **variable**, nao-secret):

```
AWS_REGION
```

Secrets necessarios no repositorio:

```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
TF_VAR_ssh_public_key, TF_VAR_app_hostname
TF_VAR_cloudflare_api_token, TF_VAR_cloudflare_account_id, TF_VAR_cloudflare_zone_id
```

> O backend (bucket/key/lock) nao e' mais secret: e' chumbado/derivado no workflow
> (`STATE_BUCKET_PREFIX` + accountId + region).

## IAM da pipeline (credenciais do CI)

Exemplos de policy minima para a identidade que o pipeline usa (a que gera as
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`). Cobre o escopo da infra e do app:
backend (S3+DynamoDB), VPC/EC2, IAM (apenas roles/instance-profile `dify-*`),
`PassRole` para EC2 e Scheduler, EventBridge Scheduler e o bucket S3 do Dify.

- [infra/iam/ci-deploy-policy.json](infra/iam/ci-deploy-policy.json) — **permissions
  policy** (o que o pipeline pode fazer). Anexe ao usuario/role do CI.
- [infra/iam/ci-trust-policy-oidc.json](infra/iam/ci-trust-policy-oidc.json) — **custom
  trust policy** de exemplo, caso prefira uma **role via OIDC do GitHub** em vez de
  access keys (recomendado). E' o JSON que vai no campo "Custom trust policy" ao criar a role.

> Distincao importante: a **trust policy** define *quem* assume a role; a **permissions
> policy** define *o que* pode fazer. Com **access keys** (setup atual) voce so precisa
> anexar a permissions policy ao usuario IAM — a trust policy nao se aplica. Com **role
> OIDC** voce usa as duas (e troca o passo `Configure AWS credentials` para `role-to-assume`).

Antes de aplicar, substitua os placeholders `<ACCOUNT_ID>` e `<REGION>`. Os buckets
seguem o padrao deterministico (Account-Regional namespace): state em
`dify-tfstate-<ACCOUNT_ID>-<REGION>` e storage do Dify em
`dify-prod-<ACCOUNT_ID>-<REGION>` (`<project>-<environment>-<accountId>-<region>`); a
tabela de lock e' `dify-tflock`. Os ARNs de IAM/Scheduler assumem o prefixo de nome
`dify-*` (variavel `project`); ajuste se mudar o `project`/`environment`.

## Camada app (deploy do Dify)

Depois que a infra esta no ar, a camada `app/` sobe o **Dify Community** na EC2 via
**SSM Run Command** — sem SSH e sem abrir portas (o CI usa as credenciais do `dify-ci`
e a instancia tem agente SSM + instance role).

Workflow `Deploy App (Dify)` (`.github/workflows/app.yml`):

- **Pull request** (paths `app/**`) -> `shellcheck` no `app/deploy.sh` (so validacao).
- **Push na `main`** (paths `app/**`) ou **`workflow_dispatch`** -> resolve a instancia pela
  tag `Name=dify-prod`, garante ela `running` (liga se estiver parada pelo agendamento),
  espera o SSM ficar `Online` e roda o `app/deploy.sh` na maquina.

O [app/deploy.sh](app/deploy.sh) e' idempotente e, na instancia: cria swap (~4 GiB), garante o
plugin `docker compose`, faz checkout do Dify na tag pinada em `/opt/dify`, monta o `.env`
(gera o `SECRET_KEY` na 1a vez e **preserva** depois; injeta `STORAGE_TYPE=s3` +
`S3_BUCKET_NAME`/`S3_REGION` + `S3_USE_AWS_MANAGED_IAM=true`) e roda `docker compose up -d`.
Nenhum segredo trafega pelo SSM — o bucket/regiao sao derivados e o `SECRET_KEY` nasce e fica
na maquina. Os containers usam `restart: always`, entao voltam sozinhos no start diario das 08h.

### Persistencia dos dados (sobrevive a recriacao da instancia)

`/opt/dify` fica num **volume EBS dedicado e persistente** (`aws_ebs_volume.data`, montado pelo
`user_data` via fstab), separado do EBS root. Ali vivem o repo do Dify, o `.env` (com o
`SECRET_KEY`) e os volumes dos bancos (Postgres/Redis/Weaviate). Como o volume tem
`prevent_destroy` e e' reanexado a cada instancia, os dados **sobrevivem a um replace/recriacao
da instancia** (troca de AMI, mudanca de `user_data`, etc.); o EBS root continua descartavel.
Os arquivos enviados pelos usuarios ja vao pro S3 (duraveis). Tamanho via `data_volume_size`
(default 20 GiB). Para destruir de proposito, remova o `prevent_destroy` ou apague o volume.

> **Migracao da instancia que ja esta no ar:** a instancia atual ainda tem os dados no EBS
> root. Aplicar esta mudanca **anexa** o volume novo mas **nao** migra nem o monta sozinho (o
> `user_data` so roda em boot novo). Veja o passo de migracao unica mais abaixo antes de
> recriar a instancia, senao ela sobe com banco vazio.

Variavel (repository **variable**, opcional):

```
DIFY_VERSION    # tag do Dify a subir; default no workflow e' 1.4.3. Ajuste para a release desejada.
```

> Reusa os secrets/variable que ja existem (`AWS_REGION`, `AWS_ACCESS_KEY_ID`,
> `AWS_SECRET_ACCESS_KEY`, `TF_VAR_app_hostname`). Como o app roda na `main`, comite os
> arquivos de `app/` + `.github/workflows/app.yml` nessa branch.

> **Permissoes:** o `dify-ci` precisa das permissoes de SSM (statements `SsmSendCommand` +
> `SsmReadInvocations` em [ci-deploy-policy.json](infra/iam/ci-deploy-policy.json)). Apos
> atualizar a policy, re-aplique:
> ```bash
> aws iam put-user-policy --user-name dify-ci --policy-name dify-ci-deploy \
>   --policy-document file://infra/iam/ci-deploy-policy.local.json
> ```

> **Versao do Dify e storage:** versoes recentes podem usar OpenDAL
> (`STORAGE_TYPE=opendal` + `OPENDAL_SCHEME=s3`). Ao trocar a tag, confira o `.env.example`
> dela e ajuste os `set_kv` do `deploy.sh` se necessario.

### E-mail (SMTP via Amazon SES) — opcional

Sem isto o Dify mostra *"Email server is not set up"* e convites de membros so saem
como link manual. O Dify **so** configura e-mail por variaveis de ambiente (nao ha tela
na UI do Community), entao o `deploy.sh` injeta as vars `MAIL_*`/`SMTP_*` no `.env`.

A **senha SMTP nunca trafega pelo SSM** nem aparece em log: o workflow a publica no
**SSM Parameter Store** (`SecureString`, em `/dify-prod/smtp_password`) a partir do secret
`SMTP_PASSWORD`, e o `deploy.sh` a le na instancia via instance role (`ssm:GetParameter`).

Para ligar:

1. **SES** (mesma regiao): verifique a identidade do remetente (dominio/e-mail) e peca
   *production access* (sair do sandbox) para enviar a qualquer destinatario.
2. **SES → SMTP settings → Create SMTP credentials** (gera usuario + senha SMTP, distintos
   das access keys da AWS).
3. Defina os **repository variables** e o **secret** (Settings do repo):
   ```
   # variables
   MAIL_TYPE=smtp
   MAIL_DEFAULT_SEND_FROM=Dify <no-reply@seu-dominio>
   SMTP_SERVER=email-smtp.us-east-1.amazonaws.com
   SMTP_PORT=465
   SMTP_USERNAME=<usuario SMTP do SES>
   SMTP_USE_TLS=true
   SMTP_OPPORTUNISTIC_TLS=false   # use true se SMTP_PORT=587
   # secret
   SMTP_PASSWORD=<senha SMTP do SES>
   ```
4. **Pre-requisito de IAM** (uma vez): a instance role precisa ler o parametro e o `dify-ci`
   precisa escreve-lo. Isso ja esta no codigo — basta aplicar:
   - `infra/compute.tf` (statements `ReadSmtpPassword`/`DecryptViaSsm`) → push na branch
     `infra` p/ o `tofu apply`.
   - `dify-ci` (statements `SsmPutSmtpParameter`/`KmsEncryptViaSsm`) → re-aplicar a policy
     (`aws iam put-user-policy ...`, ver acima).

Deixar `MAIL_TYPE` vazio mantem o e-mail desligado; o deploy roda normal sem ele.

## Custo

Maquina ligada ~50h/semana (10h x 5 dias) + S3 + EBS gp3 enxuto (root + ~US$ 1,6/mes do volume
de dados de 20 GiB), sem NAT e sem EIP: tipicamente **~US$ 12-16/mes** em `us-east-1` (fora do
free tier; estimativa de ordem de grandeza).
