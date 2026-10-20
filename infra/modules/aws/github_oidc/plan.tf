# Plan role — READ-ONLY, so `terraform plan` can run on every Provision.
#
# Trusts the management repo's main branch (no GitHub Environment), so the
# Provision workflow's plan job gets it automatically. It can read the site's
# resources and its state, take the state lock, and change nothing — the apply
# still needs the Terraform role, which only an environment job gets.
data "aws_iam_policy_document" "plan_assume" {
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
      values   = [for p in local.mgmt_sub_prefixes : "${p}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.name_prefix}-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.tf_state_bucket}", "arn:aws:s3:::${var.tf_state_bucket}/*"]
  }

  # plan takes the state lock so it never reads a half-written state: an S3
  # lockfile next to the state (lockfiles only — the state itself stays
  # read-only), plus the DynamoDB table while a client still locks with it.
  statement {
    sid       = "StateLockfile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.tf_state_bucket}/*.tflock"]
  }

  dynamic "statement" {
    for_each = var.tf_lock_table != "" ? [1] : []
    content {
      sid       = "StateLock"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
      resources = ["arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.tf_lock_table}"]
    }
  }

  # Read the site bucket's configuration (plan refreshes every setting), and any
  # other bucket of this project's (an app install's assets bucket).
  statement {
    sid       = "ReadSiteBucket"
    actions   = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration", "s3:GetAccelerateConfiguration", "s3:ListBucket"]
    resources = [var.bucket_arn, "arn:aws:s3:::${var.name_prefix}-*"]
  }

  # An app install's server Lambda, its log group and its role (modules/aws/next_app).
  statement {
    sid       = "ReadProjectFunctions"
    actions   = ["lambda:Get*", "lambda:List*"]
    resources = ["arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:${var.name_prefix}-*"]
  }

  statement {
    sid       = "ReadProjectRoles"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*"]
  }

  statement {
    sid = "ReadSiteServices"
    actions = [
      "cloudfront:Get*", "cloudfront:List*", "cloudfront:Describe*",
      "acm:Describe*", "acm:List*", "acm:GetCertificate",
      "route53:Get*", "route53:List*",
      "route53domains:Get*", "route53domains:List*",
      "apigateway:GET", "logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "${var.name_prefix}-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}
