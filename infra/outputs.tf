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
