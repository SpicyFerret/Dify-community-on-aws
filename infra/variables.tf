###############################################################################
# Identificacao / regiao
###############################################################################

variable "project" {
  description = "Nome do projeto, usado como prefixo de nomes e tags."
  type        = string
  default     = "dify"
}

variable "environment" {
  description = "Ambiente (prod, staging, etc)."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "Regiao AWS onde a infra sera provisionada."
  type        = string
  default     = "us-east-1"
}

###############################################################################
# Compute / EC2
###############################################################################

variable "instance_type" {
  description = "Tipo da instancia EC2 (minimo do Dify: 2 vCPU / 4 GiB)."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Tamanho do EBS root em GiB (SO + imagens docker + volumes dos bancos)."
  type        = number
  default     = 30
}

variable "ssh_public_key" {
  description = "Chave publica SSH para o key pair da instancia (acesso via WARP)."
  type        = string
}

###############################################################################
# Rede
###############################################################################

variable "vpc_cidr" {
  description = "CIDR da VPC dedicada."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR da subnet publica (egress only, sem inbound da internet)."
  type        = string
  default     = "10.20.1.0/24"
}

###############################################################################
# Storage Dify (S3)
#
# O nome do bucket e' deterministico (<project>-<environment>-<accountId>-<region>),
# derivado em s3.tf. Nao ha variavel de entrada.
###############################################################################

###############################################################################
# Agendamento (EventBridge Scheduler)
###############################################################################

variable "schedule_timezone" {
  description = "Fuso horario das janelas de start/stop."
  type        = string
  default     = "America/Sao_Paulo"
}

variable "start_cron" {
  description = "Expressao cron do EventBridge Scheduler para ligar a instancia."
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "stop_cron" {
  description = "Expressao cron do EventBridge Scheduler para desligar a instancia."
  type        = string
  default     = "cron(0 18 ? * MON-FRI *)"
}

###############################################################################
# Cloudflare
###############################################################################

variable "cloudflare_api_token" {
  description = "API token da Cloudflare (Account.Cloudflare Tunnel + Zone.DNS edit)."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "ID da conta Cloudflare."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "ID da zona Cloudflare onde o registro DNS sera criado."
  type        = string
}

variable "app_hostname" {
  description = "Hostname publico do Dify (ex: dify.example.com)."
  type        = string
}

variable "tunnel_name" {
  description = "Nome do Cloudflare Tunnel."
  type        = string
  default     = "dify-tunnel"
}
