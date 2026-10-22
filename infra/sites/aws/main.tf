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
  onsyte_domain    = local.onsyte_subdomain != "" ? "${local.onsyte_subdomain}.${local.domain}" : ""

  # site: false = no website here (it's hosted elsewhere); the account only runs
  # Onsyte, in a zone of its own. Same rule as client_zone in lib/client.sh.
  site      = try(local.cfg.site, true)
  zone_name = try(local.cfg.hosted_zone, local.site ? local.domain : local.onsyte_domain)
}

module "site" {
  count  = local.site ? 1 : 0
  source = "../../modules/aws/static_site_stack"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  project_name = var.client
  site_domain  = local.domain

  manage_dns       = local.domain != ""
  hosted_zone_name = local.zone_name

  create_hosted_zone   = contains(["route53-registrar", "external"], local.dns)
  registrar_in_route53 = local.dns == "route53-registrar"
  manage_www           = try(local.cfg.www, true)
  error_page_path      = try(local.cfg.error_page, "/index.html")
}

# Clients from before `site` existed have the stack at module.site.
moved {
  from = module.site
  to   = module.site[0]
}

# No site: Onsyte's zone. external = created here (delegated with 4 NS records at
# their DNS provider, or by delegate_from); existing-zone = already in the account.
resource "aws_route53_zone" "app" {
  count = !local.site && local.dns == "external" ? 1 : 0
  name  = local.zone_name
}

data "aws_route53_zone" "app" {
  count        = !local.site && local.dns == "existing-zone" ? 1 : 0
  name         = local.zone_name
  private_zone = false
}

locals {
  zone_id = local.site ? module.site[0].hosted_zone_id : one(concat(
    aws_route53_zone.app[*].zone_id, data.aws_route53_zone.app[*].zone_id,
  ))
}

module "onsyte" {
  count  = local.onsyte_subdomain != "" ? 1 : 0
  source = "../../modules/aws/next_app"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix    = "${var.client}-onsyte"
  domain         = local.onsyte_domain
  hosted_zone_id = local.zone_id
}

# The site outputs are null with site: false.
output "s3_bucket" { value = one(module.site[*].s3_bucket) }
output "cloudfront_distribution_id" { value = one(module.site[*].cloudfront_distribution_id) }
output "cloudfront_domain_name" { value = one(module.site[*].cloudfront_domain_name) }
output "site_url" { value = one(module.site[*].site_url) }
output "hosted_zone_name" { value = local.site ? module.site[0].hosted_zone_name : local.zone_name }
output "hosted_zone_name_servers" {
  value = local.site ? module.site[0].hosted_zone_name_servers : flatten(aws_route53_zone.app[*].name_servers)
}

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
    record = local.delegate_from == "" ? "" : local.zone_name
  }
}
