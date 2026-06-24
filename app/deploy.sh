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

# ---------------------------------------------------------------------------
# Diagnostico em caso de falha. O SSM trunca a saida em ~24k chars e o
# 'docker compose pull' enche o stdout, empurrando o erro real (no fim) pra
# fora da janela. Este trap despeja o essencial (disco, RAM, status e logs
# dos containers) no STDERR -- buffer separado e pequeno, entao a causa
# sempre aparece no workflow, mesmo quando o stdout estoura o limite.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329  # invocada indiretamente pelo 'trap ... EXIT' abaixo.
diag_on_fail() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  set +e
  {
    echo "===== DEPLOY FALHOU (rc=${rc}) -- diagnostico ====="
    echo "== df -h / =="; df -h /
    echo "== free -h =="; free -h
    if [ -d "$COMPOSE_DIR" ]; then
      cd "$COMPOSE_DIR" || exit "$rc"
      echo "== docker compose ps =="; docker compose ps
      echo "== docker compose logs (tail) =="; docker compose logs --tail=40
    fi
  } >&2
}
trap diag_on_fail EXIT

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
# /opt/dify e' um volume EBS persistente (montado pela infra), entao o diretorio
# pode JA existir e nao estar vazio (lost+found, ou dados de uma instancia
# anterior). 'git clone' recusa dir nao-vazio -> usamos init + fetch + checkout.
mkdir -p "$APP_DIR"
if [ ! -d "$APP_DIR/.git" ]; then
  echo "==> Inicializando repo do Dify em ${APP_DIR}"
  git -C "$APP_DIR" init -q
  git -C "$APP_DIR" remote add origin https://github.com/langgenius/dify.git
fi
echo "==> Buscando/checkout Dify ${DIFY_VERSION}"
git -C "$APP_DIR" fetch --depth 1 origin \
  "refs/tags/${DIFY_VERSION}:refs/tags/${DIFY_VERSION}"
git -C "$APP_DIR" checkout -f "refs/tags/${DIFY_VERSION}"

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
# 4c. URLs publicas do console/app.
#     O Dify monta o redirect_uri do OAuth dos datasources (Google Drive,
#     Notion, etc.) a partir destas URLs. Atras do Cloudflare Tunnel a origem
#     recebe a requisicao como HTTP em localhost:80, entao com CONSOLE_API_URL
#     vazio o Dify gera um callback 'http://...' -> o Google recusa
#     ("invalid_request / nao cumpre a politica OAuth 2.0", que exige HTTPS).
#     Fixar a URL publica HTTPS aqui resolve. So' roda com APP_HOSTNAME setado.
# ---------------------------------------------------------------------------
if [ -n "${APP_HOSTNAME:-}" ]; then
  echo "==> Configurando URLs publicas (https://${APP_HOSTNAME})"
  base_url="https://${APP_HOSTNAME}"
  set_kv CONSOLE_API_URL "$base_url"
  set_kv CONSOLE_WEB_URL "$base_url"
  set_kv SERVICE_API_URL "$base_url"
  set_kv APP_API_URL     "$base_url"
  set_kv APP_WEB_URL     "$base_url"
else
  echo "==> APP_HOSTNAME vazio; OAuth de datasources (Google Drive etc.) pode falhar." >&2
fi

# ---------------------------------------------------------------------------
# 5. Sobe os containers
#    Num upgrade de versao o 'pull' baixa o conjunto novo de imagens enquanto
#    o antigo ainda esta em uso -> pico de disco que pode estourar o EBS root.
#    Limpamos o lixo barato antes; se o pull mesmo assim falhar (sem disco),
#    paramos os containers, removemos o conjunto antigo (libera o root) e
#    tentamos de novo. Os dados ficam nos bind mounts em /opt/dify (intactos).
# ---------------------------------------------------------------------------
echo "==> docker compose pull && up -d"
docker image prune -f >/dev/null 2>&1 || true
if ! docker compose pull --quiet; then
  echo "==> 'pull' falhou (provavel falta de disco). Liberando espaco e tentando de novo." >&2
  docker compose down --remove-orphans || true
  docker image prune -af >/dev/null 2>&1 || true
  docker builder prune -af >/dev/null 2>&1 || true
  df -h / >&2 || true
  docker compose pull --quiet
fi
docker compose up -d
# O nginx resolve os upstreams (api/web) pra um IP fixo quando sobe e cacheia
# pra sempre (a config do Dify usa 'proxy_pass http://web:3000' sem 'resolver').
# Num upgrade os backends sao recriados com IPs novos, mas o nginx fica de pe
# apontando pro IP velho -> 502 "Connection refused". Reiniciar o nginx forca a
# re-resolucao pros IPs atuais. Barato (<1s) e idempotente.
docker compose restart nginx
docker image prune -f
docker compose ps

# ---------------------------------------------------------------------------
# 6. Healthcheck local (bypassa o Cloudflare; confiavel de dentro da maquina).
#    Forca IPv4 em 127.0.0.1: "localhost" pode resolver pra ::1 e dar 000
#    mesmo com o nginx no ar. Qualquer resposta HTTP do nginx (2xx/3xx/4xx)
#    ja prova que a stack subiu; so' 000 (sem conexao) ou 5xx (backend morto)
#    contam como falha -- evita falso-negativo no codigo de "/" (307/200/404).
# ---------------------------------------------------------------------------
echo "==> Aguardando o app responder em http://127.0.0.1/ ..."
for attempt in $(seq 1 30); do
  code="$(curl -4 -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || echo 000)"
  echo "  [${attempt}] HTTP ${code}"
  case "$code" in
  000 | 5*) ;; # sem conexao ou erro de gateway -> ainda subindo, aguarda
  *)
    echo "==> App OK (HTTP ${code}). Deploy concluido."
    exit 0
    ;;
  esac
  sleep 10
done
echo "ERRO: app nao respondeu (so' 000/5xx) em http://127.0.0.1/ a tempo." >&2
exit 1
