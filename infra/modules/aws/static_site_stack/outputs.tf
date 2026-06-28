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

output "deploy_role_arn" {
  description = "ARN of the deploy role the app repo assumes via OIDC (set as AWS_DEPLOY_ROLE_ARN)."
  value       = module.github_oidc.deploy_role_arn
}

output "terraform_role_arn" {
  description = "ARN of the Terraform role the mgmt repo assumes via OIDC (set as the env's AWS_TF_ROLE_ARN_* variable)."
  value       = module.github_oidc.terraform_role_arn
}
