variable "domain_name" {
  description = "Domain the certificate is issued for."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional domains on the cert (e.g. www.<domain>). Each gets its own DNS validation record."
  type        = list(string)
  default     = []
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID where DNS validation records are created."
  type        = string
}
