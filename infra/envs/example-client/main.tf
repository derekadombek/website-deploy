# VALIDATE-ONLY example client. Demonstrates the foreign-account + foreign-domain
# shape: a different AWS account, a domain that is NOT under derekadombek.com,
# the deploy role pointed at the CLIENT's app repo, and the Terraform role still
# pointed at this management repo. Proves the config parses; it is not applied.

module "site" {
  source = "../../modules/aws/static_site_stack"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = "example-client"
  site_domain  = "www.example-client.com"

  manage_dns       = true
  hosted_zone_name = "example-client.com" # client's own Route 53 zone

  # Deploy role trusts the CLIENT's app repo; Terraform role trusts this repo.
  # The client owns the app repo and adds you as admin (clean offboarding).
  deploy_github_repo = "example-client/website"
  mgmt_github_repo   = "derekadombek/website-deploy"
  github_branch      = "main"
  mgmt_environment   = "provisioning"

  # New account → it creates its own OIDC provider.
  create_oidc_provider = true

  tf_state_bucket = "example-client-tf-state"
  tf_lock_table   = "example-client-tf-locks"
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
output "deploy_role_arn" { value = module.site.deploy_role_arn }
output "terraform_role_arn" { value = module.site.terraform_role_arn }
