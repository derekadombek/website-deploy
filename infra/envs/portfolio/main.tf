# Portfolio — the apex derekadombek.com, served from the Astro `portfolio` repo.
# Your account; deploy role trusts the portfolio app repo.

module "site" {
  source = "../../modules/aws/static_site_stack"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = "portfolio"
  site_domain  = "derekadombek.com"

  manage_dns       = true
  hosted_zone_name = "derekadombek.com"

  # Serve www over HTTPS and 301 it to the apex.
  manage_www = true

  # OIDC provider + roles live in the separate access config (infra/access),
  # stood up by aws-grant-access. This env builds only the site.
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
