# Lets GitHub Actions authenticate to AWS via OIDC (no stored access keys) and
# grants a least-privilege role scoped to one bucket + one distribution.

# There can only be one GitHub OIDC provider per account. Create it here, or
# set create_oidc_provider = false to reuse an existing one.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Deploy role trusts the APP repo, branch-scoped. Pair with branch
    # protection on that branch. Deploys are frequent + low-privilege.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.deploy_github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.name_prefix}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "ListSiteBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
  }

  statement {
    sid       = "WriteSiteObjects"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    sid       = "InvalidateCloudFront"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [var.distribution_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name_prefix}-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.permissions.json
}

# --- Terraform / management role --------------------------------------------
# Much broader than the deploy role, because `terraform apply` manages the
# whole stack. Three guards keep that in check: (1) IAM access is scoped to this
# project's own roles + OIDC provider, so the role can't escalate by editing
# unrelated principals; (2) trust is keyed to the MANAGEMENT repo scoped to a
# GitHub Environment (`environment:<mgmt_environment>`), NOT a branch — so the
# only token that satisfies this trust is one minted for a job that declared
# that environment; (3) that environment has required reviewers, so the token
# (and thus this role) is unusable until a human approves. The broad role
# stands permanently but is inert without that approval.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "terraform_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.mgmt_github_repo}:environment:${var.mgmt_environment}"]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = "${var.name_prefix}-terraform"
  assume_role_policy = data.aws_iam_policy_document.terraform_assume.json
}

data "aws_iam_policy_document" "terraform" {
  # Remote state + lock, tightly scoped to the bootstrap resources.
  statement {
    sid     = "TerraformState"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.tf_state_bucket}",
      "arn:aws:s3:::${var.tf_state_bucket}/*",
    ]
  }

  statement {
    sid       = "TerraformLock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.tf_lock_table}"]
  }

  # Management plane for the services this stack creates. These services scope
  # poorly on create operations, so they're granted at the service level.
  statement {
    sid       = "ManageStackServices"
    actions   = ["s3:*", "cloudfront:*", "acm:*", "route53:*"]
    resources = ["*"]
  }

  # IAM, scoped to this project's own roles only — the escalation guard.
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*"]
  }

  # The account-level GitHub OIDC provider (single shared resource).
  statement {
    sid = "ManageOIDCProvider"
    actions = [
      "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:ListOpenIDConnectProviders",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform" {
  name   = "${var.name_prefix}-terraform"
  role   = aws_iam_role.terraform.id
  policy = data.aws_iam_policy_document.terraform.json
}
