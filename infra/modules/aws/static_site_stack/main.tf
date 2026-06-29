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

  # The hosted zone is either created here (client has no Route 53 zone yet) or
  # looked up (client already manages the domain in Route 53).
  zone_id = var.manage_dns ? (
    var.create_hosted_zone ? aws_route53_zone.primary[0].zone_id : data.aws_route53_zone.primary[0].zone_id
  ) : null
}

# Create the zone for a client who doesn't have one yet. After apply, the client
# must point their registrar's nameservers at this zone's name_servers output;
# until that delegation lands, public DNS (and ACM DNS validation) won't resolve.
resource "aws_route53_zone" "primary" {
  count = var.manage_dns && var.create_hosted_zone ? 1 : 0
  name  = var.hosted_zone_name
}

# Look up an existing zone when the client already manages the domain in Route 53.
data "aws_route53_zone" "primary" {
  count        = var.manage_dns && !var.create_hosted_zone ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = false
}

# Auto-delegation: if the domain is registered in Route 53 in this account, point
# its nameservers at the new zone so no one has to touch a registrar by hand.
# (Route 53 Domains is a us-east-1 API, hence the aliased provider.)
resource "aws_route53domains_registered_domain" "this" {
  count       = var.manage_dns && var.create_hosted_zone && var.registrar_in_route53 ? 1 : 0
  provider    = aws.us_east_1
  domain_name = var.hosted_zone_name

  dynamic "name_server" {
    for_each = aws_route53_zone.primary[0].name_servers
    content {
      name = name_server.value
    }
  }
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
  hosted_zone_id            = local.zone_id
}

# Edge router (viewer-request). Does two generic jobs, so it's attached to every
# site:
#   1. www→apex 301 (no-op unless www is actually routed to this distribution).
#   2. Clean-URL rewrite: directory-style requests ("/services/", "/about") map
#      to the underlying "…/index.html" object. Required because the private S3
#      origin (OAC) does no directory-index resolution — without it every nested
#      path 403s and falls back to the home page.
resource "aws_cloudfront_function" "router" {
  name    = "${var.project_name}-router"
  runtime = "cloudfront-js-2.0"
  comment = "www→apex redirect + clean-URL index rewrite"
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
      var uri = request.uri;
      if (uri.charAt(uri.length - 1) === '/') {
        request.uri = uri + 'index.html';
      } else if (uri.substring(uri.lastIndexOf('/') + 1).indexOf('.') === -1) {
        request.uri = uri + '/index.html';
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
  viewer_request_function_arn = aws_cloudfront_function.router.arn
}

# Point the domain at CloudFront (only when managing DNS).
resource "aws_route53_record" "site_a" {
  count   = var.manage_dns ? 1 : 0
  zone_id = local.zone_id
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
  zone_id = local.zone_id
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
  zone_id = local.zone_id
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
  zone_id = local.zone_id
  name    = local.www_domain
  type    = "AAAA"

  allow_overwrite = true

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# Keyless CI roles (OIDC provider + deploy/Terraform roles) live in the separate
# access config (infra/access), stood up once per account by the aws-grant-access
# action. This stack builds only the site and authenticates over that OIDC.
