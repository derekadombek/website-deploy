variable "name_prefix" {
  description = "Prefix for IAM role names (e.g. the project name)."
  type        = string
}

# --- Deploy role trust (the app repo) ---------------------------------------
variable "deploy_github_repo" {
  description = "App repo allowed to assume the deploy role, in 'owner/name' form. Branch-scoped."
  type        = string
}

variable "github_branch" {
  description = "Branch of the app repo allowed to deploy (restricts the deploy role's OIDC trust)."
  type        = string
  default     = "main"
}

# --- Terraform role trust (the management repo, environment-scoped) ----------
variable "mgmt_github_repo" {
  description = "Management repo allowed to run Terraform, in 'owner/name' form. Environment-scoped."
  type        = string
  default     = "derekadombek/website-deploy"
}

variable "mgmt_environment" {
  description = <<-EOT
    GitHub Environment (in the management repo) the Terraform role's trust is
    scoped to. The provisioning workflow job declares this environment, which
    has required reviewers — so the broad Terraform role is unusable until a
    human approves, even though it stands permanently.
  EOT
  type        = string
  default     = "provisioning"
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider. Exactly one env per account sets this true; the rest reuse it."
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
