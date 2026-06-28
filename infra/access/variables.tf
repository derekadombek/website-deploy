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
  description = "Management repo allowed to run Terraform (Terraform role trust, environment-scoped)."
  type        = string
  default     = "derekadombek/website-deploy"
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
