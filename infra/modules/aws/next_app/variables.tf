variable "name_prefix" {
  description = "Prefix for every resource, e.g. <client>-onsyte. Must start with the client name so the Terraform role's <client>-* scopes cover it."
  type        = string
}

variable "domain" {
  description = "Fully-qualified domain the app is served at, e.g. onsyte.acme.com."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 zone (in this account) that holds var.domain. Gets the cert validation and alias records."
  type        = string
}

variable "lambda_runtime" {
  description = "Node.js runtime for the server function."
  type        = string
  default     = "nodejs22.x"
}

variable "lambda_memory_mb" {
  description = "Server function memory. More memory also means more CPU, so faster cold starts."
  type        = number
  default     = 1024
}

variable "lambda_timeout_seconds" {
  description = "Server function timeout. API Gateway gives up at 30 s, so higher buys nothing."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "How long the server function's logs are kept."
  type        = number
  default     = 30
}

variable "throttle_burst" {
  description = "API Gateway burst limit (requests)."
  type        = number
  default     = 100
}

variable "throttle_rate" {
  description = "API Gateway steady-state limit (requests per second)."
  type        = number
  default     = 50
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 = North America + Europe (cheapest)."
  type        = string
  default     = "PriceClass_100"
}
