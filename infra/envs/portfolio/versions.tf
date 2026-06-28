terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # State for this account. A future env in the same account would reuse this
  # bucket + lock table with its own key.
  backend "s3" {
    bucket         = "website-deploy-tf-state-west"
    key            = "sites/portfolio/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "website-deploy-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Project   = "portfolio"
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "portfolio"
      ManagedBy = "Terraform"
    }
  }
}
