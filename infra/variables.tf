variable "project_name" {
  description = "Name used for tagging and resource naming."
  type        = string
  default     = "bobs-fishing-tours"
}

variable "aws_region" {
  description = "Region for non-CloudFront resources (S3 bucket, etc.)."
  type        = string
  default     = "us-west-2"
}

variable "site_domain" {
  description = "Fully-qualified domain the site is served at, e.g. bob.derekadombek.com."
  type        = string
  default     = "bob.derekadombek.com"
}

variable "hosted_zone_name" {
  description = "Existing Route 53 hosted zone the domain lives in, e.g. derekadombek.com. Must already exist in this AWS account."
  type        = string
  default     = "derekadombek.com"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the deploy role, in 'owner/name' form."
  type        = string
  default     = "derekadombek/website-deploy"
}

variable "github_branch" {
  description = "Branch allowed to deploy (restricts the OIDC trust policy)."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider. Set false to reuse an existing one."
  type        = bool
  default     = true
}

# These must match the S3 backend in versions.tf — Terraform backends can't read
# variables, so the names are repeated here to scope the CI Terraform role.
variable "tf_state_bucket" {
  description = "Name of the S3 bucket holding Terraform remote state."
  type        = string
  default     = "website-deploy-tf-state-west"
}

variable "tf_lock_table" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  type        = string
  default     = "website-deploy-tf-locks"
}
