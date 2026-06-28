# Access stack — the trust foundation a CLIENT applies (via the aws-grant-access
# action, with their own creds) so you can manage their account over OIDC after.
# It creates ONLY the OIDC provider + deploy role + Terraform role. The website
# (S3 / CloudFront / DNS) is built separately by you, over OIDC, with the site
# env's create_iam = false.
#
# The deploy role is scoped to the site bucket by its PREDICTABLE name
# (<project>-site-<account>), which doesn't exist yet — that's fine, IAM resource
# ARNs don't have to exist. CloudFront invalidation can't be scoped to a
# not-yet-created distribution, so it's granted broadly (invalidation only).

# NOTE (revisit after testing): the management role's permissions (from the
# github_oidc module) grant s3/cloudfront/acm/route53 account-WIDE within those
# services, not just this site — fine for a dedicated client account, broader if
# the client runs other things in the same account. Tighten later (scope S3 to
# the bucket, Route53 to the zone id, CloudFront by tag) if needed.
data "aws_caller_identity" "current" {}

module "github_oidc" {
  source = "../modules/aws/github_oidc"

  name_prefix          = var.project_name
  deploy_github_repo   = var.deploy_github_repo
  github_branch        = var.github_branch
  mgmt_github_repo     = var.mgmt_github_repo
  mgmt_environment     = var.mgmt_environment
  create_oidc_provider = true

  bucket_arn       = "arn:aws:s3:::${var.project_name}-site-${data.aws_caller_identity.current.account_id}"
  distribution_arn = "*"

  tf_state_bucket = var.tf_state_bucket
  tf_lock_table   = var.tf_lock_table
}
