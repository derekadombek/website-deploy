variable "project_name" {
  description = "Name used for resource naming + tagging (drives the S3 bucket + IAM role names)."
  type        = string
}

variable "site_domain" {
  description = "Fully-qualified domain the site is served at, e.g. derekadombek.com."
  type        = string
}

variable "hosted_zone_name" {
  description = "Route 53 hosted zone the domain lives in, e.g. derekadombek.com. Used only when manage_dns = true; must already exist in this account."
  type        = string
  default     = ""
}

variable "manage_dns" {
  description = <<-EOT
    When true, issue an ACM cert, attach the custom domain to CloudFront, and
    create the Route 53 alias records (requires hosted_zone_name). When false,
    skip cert + DNS and serve the CloudFront default domain — the "ship S3 only"
    recipe.
  EOT
  type        = bool
  default     = true
}

variable "manage_www" {
  description = <<-EOT
    When true (and manage_dns), also serve www.<site_domain>: add it to the cert
    + distribution and 301-redirect www→apex over HTTPS via a CloudFront Function.
    Requires the www DNS record to live in the same hosted zone.
  EOT
  type        = bool
  default     = false
}

# --- OIDC trust targets -----------------------------------------------------
variable "deploy_github_repo" {
  description = "App repo whose pushes deploy the site (deploy role trust, branch-scoped)."
  type        = string
}

variable "mgmt_github_repo" {
  description = "Repo that runs Terraform for this env (Terraform role trust, environment-scoped)."
  type        = string
  default     = "derekadombek/website-deploy"
}

variable "github_branch" {
  description = "Branch of the app repo allowed to deploy."
  type        = string
  default     = "main"
}

variable "mgmt_environment" {
  description = "GitHub Environment (in mgmt repo) the Terraform role trust is scoped to."
  type        = string
  default     = "provisioning"
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider. Exactly one env per account sets this true."
  type        = bool
  default     = true
}

# --- Terraform state (scopes the Terraform role; must match the env backend) -
variable "tf_state_bucket" {
  description = "S3 bucket holding this env's Terraform state (in this same account)."
  type        = string
}

variable "tf_lock_table" {
  description = "DynamoDB table used for this env's Terraform state locking."
  type        = string
}
