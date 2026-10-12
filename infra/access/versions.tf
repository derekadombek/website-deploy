terraform {
  required_version = ">= 1.16.5" # = .terraform-version; older can't read this state
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Partial backend: the bucket/key/region/table are passed at init time
  # (-backend-config) by the aws-grant-access action, because they're per-client.
  # The bucket is created by the action (AWS CLI) BEFORE this runs, so Terraform
  # state lives in it from the first apply — no local state, no chicken-and-egg.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform-access"
    }
  }
}
