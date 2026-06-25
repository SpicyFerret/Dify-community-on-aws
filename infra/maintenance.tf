###############################################################################
# Bucket S3 publico - pagina estatica de manutencao (failover do Cloudflare)
#
# Quando a EC2 esta desligada (janela 18h-08h / fim de semana), o Cloudflare
# Worker (workers.tf) serve o HTML deste bucket. E' um bucket DEDICADO, separado
# do bucket de storage do Dify (s3.tf), que continua 100% privado. Aqui so' ha
# conteudo publico estatico, sem dados sensiveis.
###############################################################################

resource "aws_s3_bucket" "maintenance" {
  bucket = "${local.name}-maint-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  tags = {
    Name = "${local.name}-maintenance"
  }
}

# Permite policy publica (via politica de bucket, NAO via ACL). O conteudo e' a
# pagina de manutencao - publico de proposito.
resource "aws_s3_bucket_public_access_block" "maintenance" {
  bucket = aws_s3_bucket.maintenance.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

# Leitura publica somente do objeto (GetObject). O Worker busca o HTML pelo
# endpoint REST HTTPS: https://<bucket>.s3.<region>.amazonaws.com/index.html
resource "aws_s3_bucket_policy" "maintenance" {
  bucket = aws_s3_bucket.maintenance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadObjects"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.maintenance.arn}/*"
      },
    ]
  })

  # A policy publica so' e' aceita depois que o public_access_block libera
  # block_public_policy/restrict_public_buckets.
  depends_on = [aws_s3_bucket_public_access_block.maintenance]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "maintenance" {
  bucket = aws_s3_bucket.maintenance.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Sobe o HTML versionado no repo. O `etag` (md5 do arquivo) faz o TF re-subir
# automaticamente quando o conteudo muda.
resource "aws_s3_object" "maintenance_index" {
  bucket        = aws_s3_bucket.maintenance.id
  key           = "index.html"
  source        = "${path.module}/maintenance/index.html"
  etag          = filemd5("${path.module}/maintenance/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "public, max-age=60"
}
