output "s3_bucket" {
  description = "Name of the S3 bucket holding the site (set as the S3_BUCKET repo variable)."
  value       = module.static_site.bucket_id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (set as the CLOUDFRONT_DISTRIBUTION_ID repo variable)."
  value       = module.static_site.distribution_id
}

output "cloudfront_domain_name" {
  description = "CloudFront's own domain (handy for testing before DNS propagates, or when manage_dns = false)."
  value       = module.static_site.distribution_domain_name
}

output "site_url" {
  description = "Public URL of the site."
  value       = var.manage_dns ? "https://${var.site_domain}" : "https://${module.static_site.distribution_domain_name}"
}

output "hosted_zone_name_servers" {
  description = "Nameservers of the created hosted zone — hand these to the client's registrar to delegate DNS. Empty unless create_hosted_zone = true."
  value       = var.manage_dns && var.create_hosted_zone ? aws_route53_zone.primary[0].name_servers : []
}

output "hosted_zone_name" {
  description = "The domain whose Route 53 zone this env manages (for delegation tooling). Empty when manage_dns = false."
  value       = var.manage_dns ? var.hosted_zone_name : ""
}
