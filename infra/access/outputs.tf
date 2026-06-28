output "deploy_role_arn" {
  description = "ARN of the deploy role (set as AWS_DEPLOY_ROLE_ARN on the app repo)."
  value       = module.github_oidc.deploy_role_arn
}

output "terraform_role_arn" {
  description = "ARN of the Terraform/management role (set as AWS_TF_ROLE_ARN on this env's GitHub Environment)."
  value       = module.github_oidc.terraform_role_arn
}
