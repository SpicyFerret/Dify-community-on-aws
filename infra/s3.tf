###############################################################################
# Bucket S3 - storage de arquivos do Dify (STORAGE_TYPE=s3)
###############################################################################

resource "aws_s3_bucket" "storage" {
  bucket = var.s3_bucket_name

  tags = {
    Name = "${local.name}-storage"
  }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket = aws_s3_bucket.storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

###############################################################################
# Acesso do EC2 ao bucket (via IAM role da instancia)
###############################################################################

data "aws_iam_policy_document" "s3_access" {
  statement {
    sid    = "BucketLevel"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.storage.arn]
  }

  statement {
    sid    = "ObjectLevel"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.storage.arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name   = "${local.name}-s3-access"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.s3_access.json
}
