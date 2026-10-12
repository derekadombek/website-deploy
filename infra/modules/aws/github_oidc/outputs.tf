output "deploy_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC."
  value       = aws_iam_role.deploy.arn
}

output "terraform_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes to run Terraform plan/apply."
  value       = aws_iam_role.terraform.arn
}

output "oidc_provider_arn" {
  description = "ARN of the account's GitHub OIDC provider (created or looked up)."
  value       = local.oidc_provider_arn
}
