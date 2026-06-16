output "site_url" {
  description = "Public URL of the site."
  value       = "https://${var.site_domain}"
}

output "s3_bucket" {
  description = "Name of the S3 bucket holding the site (used by the deploy workflow)."
  value       = module.static_site.bucket_id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (used for cache invalidation in CI)."
  value       = module.static_site.distribution_id
}

output "cloudfront_domain_name" {
  description = "CloudFront's own domain (handy for testing before DNS propagates)."
  value       = module.static_site.distribution_domain_name
}

output "github_deploy_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC. Add this as the AWS_DEPLOY_ROLE_ARN repo variable."
  value       = module.github_oidc.deploy_role_arn
}
