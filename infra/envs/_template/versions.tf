terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # State lives in THIS env's OWN account. The bucket + lock table are created
  # during this account's one-time bootstrap. Their names must match
  # tf_state_bucket / tf_lock_table in main.tf — backends can't read variables,
  # so the values are repeated.
  backend "s3" {
    bucket         = "REPLACE-tf-state"
    key            = "sites/REPLACE/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "REPLACE-tf-locks"
    encrypt        = true
  }
}

# Default provider — S3 / CloudFront / DNS / IAM live here.
# For your own sites, use a named profile. For a client account, use that
# account's bootstrap profile for the one-time apply; CI provisioning assumes
# the Terraform role via OIDC and needs no profile.
provider "aws" {
  region = "us-west-2"
  # profile = "REPLACE"

  default_tags {
    tags = {
      Project   = "REPLACE"
      ManagedBy = "Terraform"
    }
  }
}

# CloudFront requires its ACM certificate in us-east-1, regardless of where the
# rest of the stack lives.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  # profile = "REPLACE"

  default_tags {
    tags = {
      Project   = "REPLACE"
      ManagedBy = "Terraform"
    }
  }
}
