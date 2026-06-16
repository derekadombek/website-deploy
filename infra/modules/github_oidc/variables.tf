variable "name_prefix" {
  description = "Prefix for the IAM role name."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the role, in 'owner/name' form."
  type        = string
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

variable "bucket_arn" {
  description = "ARN of the S3 bucket the deploy role may write to."
  type        = string
}

variable "distribution_arn" {
  description = "ARN of the CloudFront distribution the deploy role may invalidate."
  type        = string
}
