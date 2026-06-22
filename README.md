# Dify-community-on-aws

Infrastructure as code para rodar o [Dify Community](https://docs.dify.ai/en/self-host/quick-start/docker-compose)
em uma unica EC2 na AWS, provisionada via **Terraform** e **GitHub Actions**.

## Arquitetura

- **EC2 `t3.medium`** (Amazon Linux 2023) em VPC dedicada, subnet publica usada apenas
  para egress (sem NAT Gateway, sem Elastic IP).
- **Launch template** com user-data que instala **Docker** e sobe o **cloudflared** como
  container, conectando a um **Cloudflare Tunnel** gerenciado pelo Terraform.
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
infra/                 # Terraform da infraestrutura
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
- Terraform >= 1.9, e (para validar localmente) [tflint](https://github.com/terraform-linters/tflint).

## Bootstrap do backend (uma vez)

O backend S3+DynamoDB precisa existir antes do primeiro `terraform init`:

```bash
AWS_REGION=us-east-1
BUCKET=dify-tfstate-<conta-id>
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

terraform -chdir=infra init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=$TF_STATE_KEY" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$TF_STATE_LOCK_TABLE"

terraform -chdir=infra plan
terraform -chdir=infra apply
```

## CI/CD (GitHub Actions)

Workflow `Deploy Infra` (`.github/workflows/infra.yml`):

- **Pull request** -> roda `fmt`, `tflint`, `validate`, `plan`.
- **Push na branch `infra`** -> aplica (`apply`).
- **`workflow_dispatch` com `destroy=true`** -> destroi a infra.

Secrets necessarios no repositorio:

```
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
TF_STATE_BUCKET, TF_STATE_KEY, TF_STATE_LOCK_TABLE
TF_VAR_ssh_public_key, TF_VAR_s3_bucket_name, TF_VAR_app_hostname
TF_VAR_cloudflare_api_token, TF_VAR_cloudflare_account_id, TF_VAR_cloudflare_zone_id
```

## Custo

Maquina ligada ~50h/semana (10h x 5 dias) + S3 + EBS gp3 enxuto, sem NAT e sem EIP:
tipicamente **~US$ 11-14/mes** em `us-east-1` (fora do free tier; estimativa de ordem de grandeza).
