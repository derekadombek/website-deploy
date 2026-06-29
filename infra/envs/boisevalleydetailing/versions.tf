terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  backend "s3" {
    bucket         = "boisevalleydetailing-tf-state"
    key            = "sites/boisevalleydetailing/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "boisevalleydetailing-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-west-2"


  default_tags {
    tags = {
      Project   = "boisevalleydetailing"
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"


  default_tags {
    tags = {
      Project   = "boisevalleydetailing"
      ManagedBy = "Terraform"
    }
  }
}
