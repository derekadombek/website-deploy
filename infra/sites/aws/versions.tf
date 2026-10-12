terraform {
  required_version = ">= 1.16.5" # = .terraform-version; older can't read this state
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Partial backend: each client's state lives in THEIR account. The bucket /
  # key / table come from clients/<name>.yaml and are passed at init by
  # infra/scripts/tf.sh — never run `terraform init` here by hand.
  backend "s3" {}
}

provider "aws" {
  region = local.cfg.region

  # Refuse to touch any account but the client's — a guard against stale creds
  # or a mis-pointed role.
  allowed_account_ids = [local.cfg.account_id]

  default_tags {
    tags = {
      Project   = var.client
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = [local.cfg.account_id]

  default_tags {
    tags = {
      Project   = var.client
      ManagedBy = "Terraform"
    }
  }
}
