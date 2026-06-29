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
  hosted_zone_name = "example.com" # the Route 53 zone for this domain

  # create_hosted_zone = false → the zone above must already exist (client
  # already on Route 53). Set true to CREATE it (client has no Route 53 yet),
  # then delegate their registrar to the hosted_zone_name_servers output.
  create_hosted_zone = false

  # registrar_in_route53 = true → the domain is registered in Route 53 in THIS
  # account, so delegation is set automatically (no manual registrar step).
  # Leave false for domains registered elsewhere; use scripts/onboard-site.sh.
  registrar_in_route53 = false

  # Also serve www.<domain> over HTTPS and 301-redirect it to the apex.
  manage_www = false

  # OIDC provider + deploy/Terraform roles are created once per account by the
  # aws-grant-access action (see infra/access); this stack builds only the site.
  # The deploy repo, mgmt environment, and state backend are configured there +
  # in versions.tf — convention: the GitHub Environment name = this env dir name.
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
output "hosted_zone_name_servers" { value = module.site.hosted_zone_name_servers }
