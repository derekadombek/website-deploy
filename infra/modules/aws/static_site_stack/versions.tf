terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
      # The caller hands in two providers: the default `aws` (where S3 /
      # CloudFront / DNS / IAM live) and `aws.us_east_1` (where CloudFront
      # requires its ACM certificate). Declaring the alias here lets the
      # module stay account-agnostic — the env dir decides the actual accounts.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
