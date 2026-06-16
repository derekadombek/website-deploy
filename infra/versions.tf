terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # --- Remote state (recommended for real use) -----------------------------
  # Once you have a state bucket + lock table, uncomment and `terraform init
  # -migrate-state`. Left local by default so the demo runs with zero setup.
  #
  # backend "s3" {
  #   bucket         = "my-tf-state-bucket"
  #   key            = "static-site-deploy-pipeline/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "my-tf-locks"
  #   encrypt        = true
  # }
}

# Default provider — most resources live here.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

# CloudFront requires its ACM certificate in us-east-1, regardless of the
# region everything else lives in. This aliased provider handles that.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}
