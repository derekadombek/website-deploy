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

variable "tf_state_bucket" {
  description = "Name of the S3 bucket holding Terraform remote state (scopes the CI Terraform role's state access)."
  type        = string
}

variable "tf_lock_table" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  type        = string
}
