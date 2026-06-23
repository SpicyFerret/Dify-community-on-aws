#!/usr/bin/env bash
#
# Deploy do Dify Community na EC2. Executado COMO ROOT na instancia via
# SSM Run Command (AWS-RunShellScript), disparado pelo workflow app.yml.
# Idempotente: pode rodar quantas vezes quiser.
#
# Variaveis de ambiente esperadas (exportadas pelo workflow antes deste script):
#   DIFY_VERSION    - tag do repo do Dify a fazer checkout (ex.: 1.4.3)
#   S3_BUCKET_NAME  - bucket de storage (dify-prod-<accountId>-<region>)
#   S3_REGION       - regiao do bucket (ex.: us-east-1)
#
set -euo pipefail

: "${DIFY_VERSION:?DIFY_VERSION nao definido}"
: "${S3_BUCKET_NAME:?S3_BUCKET_NAME nao definido}"
: "${S3_REGION:?S3_REGION nao definido}"

APP_DIR=/opt/dify
COMPOSE_DIR="$APP_DIR/docker"
ENV_FILE="$COMPOSE_DIR/.env"

echo "==> Deploy Dify ${DIFY_VERSION} | bucket=${S3_BUCKET_NAME} | region=${S3_REGION}"

# ---------------------------------------------------------------------------
# 0. Pacotes basicos (AL2023 nao traz git por padrao)
# ---------------------------------------------------------------------------
for pkg in git tar; do
  command -v "$pkg" >/dev/null 2>&1 || dnf install -y "$pkg"
done

# ---------------------------------------------------------------------------
# 1. Swap ~4 GiB (folga de RAM no t3.medium com ~11 containers; idempotente)
# ---------------------------------------------------------------------------
if ! swapon --show | grep -q '/swapfile'; then
  echo "==> Criando swapfile de 4 GiB"
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# ---------------------------------------------------------------------------
# 2. Plugin docker compose v2 (idempotente)
# ---------------------------------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  echo "==> Instalando plugin docker compose v2"
  install -d /usr/libexec/docker/cli-plugins
  curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  chmod +x /usr/libexec/docker/cli-plugins/docker-compose
fi

# ---------------------------------------------------------------------------
# 3. Clone / checkout do Dify na tag pinada (preserva o .env entre deploys)
# ---------------------------------------------------------------------------
if [ ! -d "$APP_DIR/.git" ]; then
  echo "==> Clonando Dify ${DIFY_VERSION}"
  git clone --depth 1 --branch "$DIFY_VERSION" \
    https://github.com/langgenius/dify.git "$APP_DIR"
else
  echo "==> Atualizando Dify para ${DIFY_VERSION}"
  git -C "$APP_DIR" fetch --depth 1 origin \
    "refs/tags/${DIFY_VERSION}:refs/tags/${DIFY_VERSION}"
  git -C "$APP_DIR" checkout -f "refs/tags/${DIFY_VERSION}"
fi

cd "$COMPOSE_DIR" || exit 1

# ---------------------------------------------------------------------------
# 4. .env: base na 1a vez (gera SECRET_KEY); preserva segredos nas proximas
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  echo "==> Criando .env a partir do .env.example (com SECRET_KEY novo)"
  cp .env.example "$ENV_FILE"
  # openssl evita o SIGPIPE de 'tr </dev/urandom | head' sob 'set -o pipefail'.
  SECRET_KEY="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | base64)"
  sed -i "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" "$ENV_FILE"
fi

# Define ou substitui KEY=VALUE no .env (idempotente).
set_kv() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

echo "==> Aplicando config de storage S3 (IAM-managed, sem chaves)"
# Nota: versoes recentes do Dify podem usar OpenDAL (STORAGE_TYPE=opendal +
# OPENDAL_SCHEME=s3). Ao trocar a tag, confira o .env.example dela e ajuste aqui.
set_kv STORAGE_TYPE           s3
set_kv S3_BUCKET_NAME         "$S3_BUCKET_NAME"
set_kv S3_REGION              "$S3_REGION"
set_kv S3_USE_AWS_MANAGED_IAM true
set_kv S3_ENDPOINT            ""

# ---------------------------------------------------------------------------
# 4b. E-mail (SMTP via Amazon SES) - OPCIONAL.
#     So roda quando MAIL_TYPE chega preenchido (vars do workflow). A senha
#     NUNCA trafega pelo SSM: e' lida do SSM Parameter Store (SecureString)
#     pela instance role, igual o SECRET_KEY nunca sai da maquina.
# ---------------------------------------------------------------------------
if [ -n "${MAIL_TYPE:-}" ]; then
  echo "==> Configurando e-mail (MAIL_TYPE=${MAIL_TYPE})"
  : "${SMTP_PASSWORD_PARAM:?SMTP_PASSWORD_PARAM nao definido (necessario com MAIL_TYPE)}"

  # AWS CLI v2 (o AL2023 nao traz por padrao) para ler o Parameter Store.
  if ! command -v aws >/dev/null 2>&1; then
    echo "==> Instalando AWS CLI v2"
    command -v unzip >/dev/null 2>&1 || dnf install -y unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
      -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update
  fi

  echo "==> Lendo senha SMTP de ${SMTP_PASSWORD_PARAM} (Parameter Store)"
  SMTP_PASSWORD="$(aws ssm get-parameter \
    --name "$SMTP_PASSWORD_PARAM" --with-decryption \
    --region "$S3_REGION" \
    --query 'Parameter.Value' --output text)"

  set_kv MAIL_TYPE              "$MAIL_TYPE"
  set_kv MAIL_DEFAULT_SEND_FROM "${MAIL_DEFAULT_SEND_FROM:-}"
  set_kv SMTP_SERVER            "${SMTP_SERVER:-}"
  set_kv SMTP_PORT              "${SMTP_PORT:-465}"
  set_kv SMTP_USERNAME          "${SMTP_USERNAME:-}"
  set_kv SMTP_PASSWORD          "$SMTP_PASSWORD"
  set_kv SMTP_USE_TLS           "${SMTP_USE_TLS:-true}"
  set_kv SMTP_OPPORTUNISTIC_TLS "${SMTP_OPPORTUNISTIC_TLS:-false}"
  unset SMTP_PASSWORD
else
  echo "==> E-mail nao configurado (MAIL_TYPE vazio); pulando."
fi

# ---------------------------------------------------------------------------
# 5. Sobe os containers
# ---------------------------------------------------------------------------
echo "==> docker compose pull && up -d"
docker compose pull
docker compose up -d
docker image prune -f
docker compose ps

# ---------------------------------------------------------------------------
# 6. Healthcheck local (bypassa o Cloudflare; confiavel de dentro da maquina).
#    O Dify responde 307 em "/" (redirect p/ /apps|/install).
# ---------------------------------------------------------------------------
echo "==> Aguardando o app responder em http://localhost/ ..."
for attempt in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ || echo 000)"
  echo "  [${attempt}] HTTP ${code}"
  case "$code" in
  200 | 301 | 302 | 307 | 308)
    echo "==> App OK (HTTP ${code}). Deploy concluido."
    exit 0
    ;;
  esac
  sleep 10
done
echo "ERRO: app nao respondeu 2xx/3xx em http://localhost/ a tempo." >&2
exit 1
