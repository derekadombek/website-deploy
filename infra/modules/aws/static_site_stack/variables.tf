variable "project_name" {
  description = "Name used for resource naming + tagging (drives the S3 bucket + IAM role names)."
  type        = string
}

variable "site_domain" {
  description = "Fully-qualified domain the site is served at, e.g. derekadombek.com."
  type        = string
}

variable "hosted_zone_name" {
  description = "Route 53 hosted zone the domain lives in, e.g. derekadombek.com. Used only when manage_dns = true; must already exist in this account."
  type        = string
  default     = ""
}

variable "manage_dns" {
  description = <<-EOT
    When true, issue an ACM cert, attach the custom domain to CloudFront, and
    create the Route 53 alias records (requires hosted_zone_name). When false,
    skip cert + DNS and serve the CloudFront default domain — the "ship S3 only"
    recipe.
  EOT
  type        = bool
  default     = true
}

variable "create_hosted_zone" {
  description = <<-EOT
    When true (and manage_dns), CREATE the Route 53 hosted zone for this domain
    instead of looking up an existing one — for a client who doesn't have Route 53
    DNS yet. After apply, delegate the registrar's nameservers to the
    hosted_zone_name_servers output. When false, the zone must already exist.
  EOT
  type        = bool
  default     = false
}

variable "registrar_in_route53" {
  description = <<-EOT
    When true (with create_hosted_zone), the domain is registered in Route 53 /
    Amazon Registrar in THIS account, so set its nameservers to the new zone
    automatically — no manual registrar step. Leave false for domains registered
    elsewhere (GoDaddy, Namecheap, …); delegate those by hand.
  EOT
  type        = bool
  default     = false
}

variable "manage_www" {
  description = <<-EOT
    When true (and manage_dns), also serve www.<site_domain>: add it to the cert
    + distribution and 301-redirect www→apex over HTTPS via a CloudFront Function.
    Requires the www DNS record to live in the same hosted zone.
  EOT
  type        = bool
  default     = false
}
