terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend remoto S3 + lock em DynamoDB.
  # A configuracao concreta (bucket/key/region/dynamodb_table) e injetada via
  # `-backend-config` no `terraform init` (ver workflow e README).
  backend "s3" {}
}
