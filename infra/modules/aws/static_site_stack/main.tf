# Bundle "recipe": the full static-site stack for one site, wiring the building
# blocks together so an env dir only has to supply per-site values.
#
#   acm_certificate (us-east-1) ─┐
#                                ├─► static_site (S3 + CloudFront) ─► Route 53 alias
#                  github_oidc ──┘        (deploy + terraform roles)
#
# Account-agnostic: it uses the providers handed in by the caller and derives
# the account id from aws_caller_identity, so IAM scoping is correct in any
# account. The manage_dns flag gates everything DNS/TLS (cert + alias records),
# letting the same module also do "ship S3 only".

locals {
  # www handling only makes sense when we own the domain + cert.
  www_enabled = var.manage_dns && var.manage_www
  www_domain  = "www.${var.site_domain}"
}

# DNS zone is looked up only when we manage DNS.
data "aws_route53_zone" "primary" {
  count        = var.manage_dns ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

# TLS certificate (us-east-1, as CloudFront requires). Skipped when manage_dns
# is false.
module "certificate" {
  count  = var.manage_dns ? 1 : 0
  source = "../acm_certificate"
  providers = {
    aws = aws.us_east_1
  }

  domain_name               = var.site_domain
  subject_alternative_names = local.www_enabled ? [local.www_domain] : []
  hosted_zone_id            = data.aws_route53_zone.primary[0].zone_id
}

# Redirect www→apex over HTTPS at the edge. Apex requests pass through
# unchanged; only www hosts get a 301. Generic (derives the apex by stripping
# the leading "www."), so it needs no per-site config.
resource "aws_cloudfront_function" "www_redirect" {
  count   = local.www_enabled ? 1 : 0
  name    = "${var.project_name}-www-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "301 redirect www.<domain> to the apex"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var host = request.headers.host.value;
      if (host.indexOf('www.') === 0) {
        return {
          statusCode: 301,
          statusDescription: 'Moved Permanently',
          headers: { location: { value: 'https://' + host.substring(4) + request.uri } }
        };
      }
      return request;
    }
  EOT
}

# Private S3 origin + CloudFront CDN. Gets the cert when managing DNS, otherwise
# serves the CloudFront default domain.
module "static_site" {
  source = "../static_site"

  name_prefix                 = var.project_name
  site_domain                 = var.site_domain
  acm_certificate_arn         = var.manage_dns ? module.certificate[0].certificate_arn : ""
  extra_aliases               = local.www_enabled ? [local.www_domain] : []
  viewer_request_function_arn = local.www_enabled ? aws_cloudfront_function.www_redirect[0].arn : ""
}

# Point the domain at CloudFront (only when managing DNS).
resource "aws_route53_record" "site_a" {
  count   = var.manage_dns ? 1 : 0
  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = var.site_domain
  type    = "A"

  # Adopt the existing apex record (old hosting) instead of failing on it.
  allow_overwrite = true

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_aaaa" {
  count   = var.manage_dns ? 1 : 0
  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = var.site_domain
  type    = "AAAA"

  allow_overwrite = true

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# Point www at the same distribution (the redirect function 301s it to apex).
resource "aws_route53_record" "www_a" {
  count   = local.www_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = local.www_domain
  type    = "A"

  # Adopt the existing www record (old S3-website redirect) instead of failing.
  allow_overwrite = true

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_aaaa" {
  count   = local.www_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.primary[0].zone_id
  name    = local.www_domain
  type    = "AAAA"

  allow_overwrite = true

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# Keyless CI roles: deploy role (app repo, branch-scoped) + Terraform role
# (mgmt repo, environment-scoped), both scoped to this site's resources.
module "github_oidc" {
  source = "../github_oidc"

  name_prefix          = var.project_name
  deploy_github_repo   = var.deploy_github_repo
  github_branch        = var.github_branch
  mgmt_github_repo     = var.mgmt_github_repo
  mgmt_environment     = var.mgmt_environment
  create_oidc_provider = var.create_oidc_provider
  bucket_arn           = module.static_site.bucket_arn
  distribution_arn     = module.static_site.distribution_arn
  tf_state_bucket      = var.tf_state_bucket
  tf_lock_table        = var.tf_lock_table
}
