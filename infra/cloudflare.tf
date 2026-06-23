###############################################################################
# Cloudflare Tunnel (Zero Trust)
# Provider cloudflare ~> 5. O connector roda como container Docker na EC2 e puxa
# a config (ingress / warp-routing) remotamente via token gerenciado aqui.
###############################################################################

resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.cloudflare_account_id
  name          = var.tunnel_name
  tunnel_secret = random_bytes.tunnel_secret.base64
  config_src    = "cloudflare"
}

# Config remota do tunnel: roteamento HTTP do Dify + warp-routing p/ SSH privado.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = [
      {
        hostname = var.app_hostname
        service  = "http://localhost:80"
      },
      {
        service = "http_status:404"
      },
    ]

    warp_routing = {
      enabled = true
    }
  }
}

# Rota de rede privada: permite que clientes WARP alcancem o CIDR da VPC
# (ex: SSH no IP privado da EC2) atraves do tunnel.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "vpc" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
  network    = var.vpc_cidr
  comment    = "${local.name} - VPC privada (SSH via WARP)"
}

# Token usado pelo connector (injetado no user-data da instancia).
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

###############################################################################
# DNS - CNAME do app apontando para o tunnel
###############################################################################

resource "cloudflare_dns_record" "app" {
  zone_id = var.cloudflare_zone_id
  name    = var.app_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
