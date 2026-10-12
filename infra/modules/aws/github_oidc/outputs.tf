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

output "plan_role_arn" {
  description = "ARN of the read-only plan role (used by the Provision workflow's unapproved plan job)."
  value       = aws_iam_role.plan.arn
}

output "mgmt_sub_prefixes" {
  description = "OIDC subject prefixes the management repo's tokens can carry (classic + immutable when known)."
  value       = local.mgmt_sub_prefixes
}
