variable "domain_name" {
  description = "Domain the certificate is issued for."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID where DNS validation records are created."
  type        = string
}
