terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # VALIDATE-ONLY EXAMPLE — a client in a DIFFERENT AWS account with a DIFFERENT
  # domain. State lives in the client's own account (placeholder names below).
  # Verify with `terraform init -backend=false` + `terraform validate`; do not
  # `terraform apply` from this checkout.
  backend "s3" {
    bucket         = "example-client-tf-state"
    key            = "sites/example-client/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "example-client-tf-locks"
    encrypt        = true
  }
}

# The client account's bootstrap profile (used only for the one-time apply;
# CI provisioning assumes the Terraform role via OIDC, no profile).
provider "aws" {
  region = "us-east-1"
  # profile = "example-client"

  default_tags {
    tags = {
      Project   = "example-client"
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  # profile = "example-client"

  default_tags {
    tags = {
      Project   = "example-client"
      ManagedBy = "Terraform"
    }
  }
}
