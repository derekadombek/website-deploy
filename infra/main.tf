# Root composition: look up the DNS zone, then wire the three modules together.
#
#   acm_certificate (us-east-1)  ->  static_site (S3 + CloudFront)  ->  DNS alias
#                                         ^
#                                 github_oidc (deploy role)

data "aws_route53_zone" "primary" {
  name         = var.hosted_zone_name
  private_zone = false
}

# TLS certificate. Runs in us-east-1 because CloudFront requires it there.
module "certificate" {
  source = "./modules/acm_certificate"
  providers = {
    aws = aws.us_east_1
  }

  domain_name    = var.site_domain
  hosted_zone_id = data.aws_route53_zone.primary.zone_id
}

# Private S3 origin + CloudFront CDN with the validated certificate attached.
module "static_site" {
  source = "./modules/static_site"

  name_prefix         = var.project_name
  site_domain         = var.site_domain
  acm_certificate_arn = module.certificate.certificate_arn
}

# Point the domain at CloudFront.
resource "aws_route53_record" "site_a" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.site_domain
  type    = "A"

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_aaaa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.site_domain
  type    = "AAAA"

  alias {
    name                   = module.static_site.distribution_domain_name
    zone_id                = module.static_site.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# Keyless CI deploy role, scoped to exactly this bucket + distribution.
module "github_oidc" {
  source = "./modules/github_oidc"

  name_prefix          = var.project_name
  github_repo          = var.github_repo
  github_branch        = var.github_branch
  create_oidc_provider = var.create_oidc_provider
  bucket_arn           = module.static_site.bucket_arn
  distribution_arn     = module.static_site.distribution_arn
}
