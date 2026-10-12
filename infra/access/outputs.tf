output "deploy_role_arn" {
  description = "ARN of the deploy role (set as AWS_DEPLOY_ROLE_ARN on the app repo)."
  value       = module.github_oidc.deploy_role_arn
}

output "terraform_role_arn" {
  description = "ARN of the Terraform/management role (set as AWS_TF_ROLE_ARN on this env's GitHub Environment)."
  value       = module.github_oidc.terraform_role_arn
}

output "dns_delegation_role_arn" {
  description = "ARN of the DNS-delegation role (empty unless delegation_zone_name is set)."
  value       = var.delegation_zone_name != "" ? aws_iam_role.dns_delegation[0].arn : ""
}

output "plan_role_arn" {
  description = "ARN of the read-only plan role (derived by the Provision workflow from the client file)."
  value       = module.github_oidc.plan_role_arn
}
