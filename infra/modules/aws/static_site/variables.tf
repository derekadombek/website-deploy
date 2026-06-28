variable "name_prefix" {
  description = "Prefix for named resources (e.g. the project name)."
  type        = string
}

variable "site_domain" {
  description = "Domain the site is served at. Also used as the S3 bucket name."
  type        = string
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of a validated ACM certificate in us-east-1 for the domain. Leave empty
    to serve the CloudFront default domain (*.cloudfront.net) with no custom
    alias — the "ship S3 only" recipe used when manage_dns = false.
  EOT
  type        = string
  default     = ""
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 = North America + Europe (cheapest)."
  type        = string
  default     = "PriceClass_100"
}

variable "extra_aliases" {
  description = "Additional CNAMEs to serve on the distribution (e.g. www.<domain>). Only used when a cert is attached."
  type        = list(string)
  default     = []
}

variable "viewer_request_function_arn" {
  description = "Optional CloudFront Function ARN to run on viewer-request (e.g. a www→apex redirect). Empty = none."
  type        = string
  default     = ""
}
