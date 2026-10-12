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
  default     = "derekadombek/website-deploy-clients"
}

variable "mgmt_github_repo_ids" {
  description = "Numeric GitHub ids of the management repo as '<ownerId>/<repoId>' — also trusts GitHub's immutable subject format. Empty = known ids for the default repo, else classic format only."
  type        = string
  default     = ""
}

variable "mgmt_environment" {
  description = <<-EOT
    GitHub Environment (in the management repo) the Terraform role's trust is
    scoped to. Only a job in the management repo that declares this
    environment can get the broad Terraform role.
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

variable "deploy_github_repo_owner_id" {
  description = "Numeric GitHub id of the app repo's owner — with deploy_github_repo_id, also trusts GitHub's immutable subject format. Empty = classic format only."
  type        = string
  default     = ""
}

variable "deploy_github_repo_id" {
  description = "Numeric GitHub id of the app repo (see deploy_github_repo_owner_id)."
  type        = string
  default     = ""
}
