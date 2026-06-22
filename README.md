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
.github/workflows/infra.yml   # pipeline (fmt, tflint, validate, plan, apply/destroy)
.env.infra.example     # variaveis da infra
.env.app.example       # variaveis do app (integracao com S3)
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

## Custo

Maquina ligada ~50h/semana (10h x 5 dias) + S3 + EBS gp3 enxuto, sem NAT e sem EIP:
tipicamente **~US$ 11-14/mes** em `us-east-1` (fora do free tier; estimativa de ordem de grandeza).
