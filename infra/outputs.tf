output "instance_id" {
  description = "ID da instancia EC2 que roda o Dify."
  value       = aws_instance.dify.id
}

output "instance_private_ip" {
  description = "IP privado da instancia (acesso SSH via WARP / warp-routing)."
  value       = aws_instance.dify.private_ip
}

output "app_url" {
  description = "URL publica do Dify (via Cloudflare Tunnel)."
  value       = "https://${var.app_hostname}"
}

output "tunnel_id" {
  description = "ID do Cloudflare Tunnel."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "vpc_id" {
  description = "ID da VPC dedicada."
  value       = aws_vpc.this.id
}

output "s3_bucket_name" {
  description = "Nome do bucket S3 usado como storage de arquivos do Dify."
  value       = aws_s3_bucket.storage.bucket
}

output "data_volume_id" {
  description = "ID do volume EBS persistente (/opt/dify: repo, .env e bancos)."
  value       = aws_ebs_volume.data.id
}

output "maintenance_bucket_name" {
  description = "Bucket S3 publico com a pagina de manutencao (servida pelo Worker no failover)."
  value       = aws_s3_bucket.maintenance.bucket
}

output "maintenance_page_url" {
  description = "URL HTTPS direta do HTML de manutencao no bucket (origem usada pelo Worker)."
  value       = "https://${aws_s3_bucket.maintenance.bucket_regional_domain_name}/${aws_s3_object.maintenance_index.key}"
}
