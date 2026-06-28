# Copy-me skeleton for a new site. To onboard one:
#   1. cp -r infra/envs/_template infra/envs/<site>
#   2. Replace every REPLACE below + fill the backend in versions.tf.
#   3. cd infra/envs/<site> && terraform init && terraform plan
# See infra/README.md for the full per-account onboarding guide.

module "site" {
  source = "../../modules/aws/static_site_stack"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = "REPLACE" # drives the S3 bucket + IAM role names
  site_domain  = "REPLACE.example.com"

  # DNS / TLS. Set manage_dns = false to skip cert + DNS and ship S3-only
  # (CloudFront default domain); hosted_zone_name is then unused.
  manage_dns       = true
  hosted_zone_name = "example.com" # existing Route 53 zone in THIS account

  # Also serve www.<domain> over HTTPS and 301-redirect it to the apex.
  manage_www = false

  # OIDC trust targets — keep these two distinct.
  deploy_github_repo = "owner/app-repo"              # deploy role: the app repo
  mgmt_github_repo   = "derekadombek/website-deploy" # terraform role: this repo
  github_branch      = "main"
  mgmt_environment   = "provisioning"

  # The GitHub OIDC provider is per-account: true in exactly ONE env per account.
  create_oidc_provider = true

  # Must match the backend block in versions.tf (scopes the Terraform role).
  tf_state_bucket = "REPLACE-tf-state"
  tf_lock_table   = "REPLACE-tf-locks"
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
output "deploy_role_arn" { value = module.site.deploy_role_arn }
output "terraform_role_arn" { value = module.site.terraform_role_arn }
