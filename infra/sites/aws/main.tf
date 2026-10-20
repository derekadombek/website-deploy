# One root for every AWS client. Which client it builds is chosen by
# var.client (set by infra/scripts/tf.sh); everything client-specific comes
# from clients/<client>.yaml. See clients/README.md for the fields.

variable "client" {
  description = "Client name = clients/<client>.yaml."
  type        = string
}

variable "clients_dir" {
  description = "Folder holding the client files (CLIENTS_DIR, set by infra/scripts/tf.sh). Empty = clients/ in this repo."
  type        = string
  default     = ""
}

locals {
  clients_dir = var.clients_dir != "" ? var.clients_dir : "${path.module}/../../../clients"
  cfg         = yamldecode(file("${local.clients_dir}/${var.client}.yaml"))

  domain        = try(local.cfg.domain, "")
  dns           = try(local.cfg.dns, "existing-zone")
  delegate_from = try(local.cfg.delegate_from, "")

  # Optional Onsyte install at <onsyte_subdomain>.<domain>; needs a domain (it
  # goes in the same zone). Code and settings are shipped by Deploy Onsyte.
  onsyte_subdomain = try(local.cfg.onsyte_subdomain, "")
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

module "onsyte" {
  count  = local.onsyte_subdomain != "" ? 1 : 0
  source = "../../modules/aws/next_app"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix    = "${var.client}-onsyte"
  domain         = "${local.onsyte_subdomain}.${local.domain}"
  hosted_zone_id = module.site.hosted_zone_id
}

output "s3_bucket" { value = module.site.s3_bucket }
output "cloudfront_distribution_id" { value = module.site.cloudfront_distribution_id }
output "cloudfront_domain_name" { value = module.site.cloudfront_domain_name }
output "site_url" { value = module.site.site_url }
output "hosted_zone_name" { value = module.site.hosted_zone_name }
output "hosted_zone_name_servers" { value = module.site.hosted_zone_name_servers }

# Read by Deploy Onsyte: where to ship the release. null = no Onsyte here.
output "onsyte" {
  value = local.onsyte_subdomain == "" ? null : {
    url                  = module.onsyte[0].url
    assets_bucket        = module.onsyte[0].assets_bucket
    server_function_name = module.onsyte[0].server_function_name
    distribution_id      = module.onsyte[0].distribution_id
  }
}

# Which parent zone holds this client's NS record (delegate_from). Kept in state
# so that when delegate_from is removed or changed, Provision still knows where
# the old record is and deletes it (client_stale_delegation); Teardown too.
output "delegation" {
  value = {
    parent = local.delegate_from
    record = local.delegate_from == "" ? "" : try(local.cfg.hosted_zone, local.domain)
  }
}
