# One root for every AWS client. Which client it builds is chosen by
# var.client (set by infra/scripts/tf.sh); everything client-specific comes
# from clients/<client>.yaml. See clients/README.md for the fields.

variable "client" {
  description = "Client name = clients/<client>.yaml."
  type        = string
}

locals {
  cfg = yamldecode(file("${path.module}/../../../clients/${var.client}.yaml"))

  domain = try(local.cfg.domain, "")
  dns    = try(local.cfg.dns, "existing-zone")
}

module "site" {
  source = "../../modules/aws/static_site_stack"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.client
  site_domain  = local.domain

  manage_dns       = local.domain != ""
  hosted_zone_name = try(local.cfg.hosted_zone, local.domain)

  create_hosted_zone   = contains(["route53-registrar", "external"], local.dns)
  registrar_in_route53 = local.dns == "route53-registrar"
  manage_www           = try(local.cfg.www, true)
  error_page_path      = try(local.cfg.error_page, "/index.html")
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
output "hosted_zone_name" { value = module.site.hosted_zone_name }
output "hosted_zone_name_servers" { value = module.site.hosted_zone_name_servers }
