output "site_url" {
  description = "Public URL of the site."
  value       = "https://${var.site_domain}"
}

output "s3_bucket" {
  description = "Name of the S3 bucket holding the site (used by the deploy workflow)."
  value       = aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (used for cache invalidation in CI)."
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  description = "CloudFront's own domain (handy for testing before DNS propagates)."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "github_deploy_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC. Add this as the AWS_DEPLOY_ROLE_ARN repo variable/secret."
  value       = aws_iam_role.github_deploy.arn
}
