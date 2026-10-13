variable "aws_region" {
  description = "Region for the (predictable) site bucket the deploy role is scoped to + the state bucket."
  type        = string
}

variable "project_name" {
  description = "Project name — must match the site env's project_name (drives the predictable bucket name + role names)."
  type        = string
}

variable "deploy_github_repo" {
  description = "App repo that deploys the site (deploy role trust, branch-scoped)."
  type        = string
}

variable "github_branch" {
  description = "Branch of the app repo allowed to deploy."
  type        = string
  default     = "main"
}

variable "mgmt_github_repo" {
  description = "Management repo allowed to run Terraform (Terraform role trust, environment-scoped). The private clients repo, whose workflows call this package's."
  type        = string
  default     = "derekadombek/website-deploy-clients"
}

variable "mgmt_github_repo_ids" {
  description = "Management repo's numeric ids '<ownerId>/<repoId>' (GitHub's immutable subject). Empty = known for the default repo."
  type        = string
  default     = ""
}

variable "mgmt_environment" {
  description = "GitHub Environment (in the mgmt repo) the Terraform role trust is scoped to — same as the site env name."
  type        = string
}

variable "tf_state_bucket" {
  description = "State bucket (created by the action) — scopes the Terraform role's state access."
  type        = string
}

variable "tf_lock_table" {
  description = "State lock table (created by the action)."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the account's GitHub OIDC provider. false = reuse the one that already exists (an account can only have one). grant-access.sh decides this automatically."
  type        = bool
  default     = true
}

variable "delegation_zone_name" {
  description = "Route 53 zone in this account whose subdomains other clients may delegate to themselves (e.g. acme.com). Empty = no delegation role."
  type        = string
  default     = ""
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
