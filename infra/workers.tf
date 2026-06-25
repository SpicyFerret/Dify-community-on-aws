###############################################################################
# Cloudflare Worker - failover para a pagina de manutencao
#
# Roda no route `<app_hostname>/*`. Normalmente e' pass-through (repassa para o
# tunnel). Quando a EC2 esta desligada e o tunnel some, o Cloudflare devolve
# 521-530 e o Worker serve o HTML do bucket publico (maintenance.tf) com 503.
# Codigo em worker/maintenance-failover.js.
###############################################################################

resource "cloudflare_workers_script" "maintenance_failover" {
  account_id  = var.cloudflare_account_id
  script_name = "${local.name}-maintenance-failover"

  content     = file("${path.module}/worker/maintenance-failover.js")
  main_module = "maintenance-failover.js"

  compatibility_date = "2025-06-01"

  # URL HTTPS (REST) do HTML de manutencao no bucket publico. bucket_regional_domain_name
  # = <bucket>.s3.<region>.amazonaws.com (regional -> HTTPS valido em qualquer regiao).
  bindings = [
    {
      name = "MAINTENANCE_URL"
      type = "plain_text"
      text = "https://${aws_s3_bucket.maintenance.bucket_regional_domain_name}/${aws_s3_object.maintenance_index.key}"
    },
  ]
}

# Liga o Worker ao hostname publico do Dify. O DNS precisa estar proxied (esta:
# cloudflare.tf, proxied = true) para o route ser avaliado no edge.
resource "cloudflare_workers_route" "maintenance_failover" {
  zone_id = var.cloudflare_zone_id
  pattern = "${var.app_hostname}/*"
  script  = cloudflare_workers_script.maintenance_failover.script_name
}
