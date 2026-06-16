variable "name_prefix" {
  description = "Prefix for named resources (e.g. the project name)."
  type        = string
}

variable "site_domain" {
  description = "Domain the site is served at. Also used as the S3 bucket name."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ARN of a validated ACM certificate in us-east-1 for the domain."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 = North America + Europe (cheapest)."
  type        = string
  default     = "PriceClass_100"
}
