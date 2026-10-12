# Optional DNS-delegation role: lets OTHER clients' provisioning add the NS
# record that delegates a subdomain of a zone in THIS account (e.g.
# bob.derekadombek.com from derekadombek.com). Only created when
# delegation_zone_name is set.
#
# Trust: any GitHub Environment job in the management repo (only its writers
# can add one).
# Permissions are deliberately tiny: NS records only, in this one zone, never the
# zone apex — the worst it can do is point a subdomain somewhere else.

data "aws_route53_zone" "delegation" {
  count = var.delegation_zone_name != "" ? 1 : 0
  name  = var.delegation_zone_name
}

locals {
  delegation_zone = trimsuffix(lower(var.delegation_zone_name), ".")
}

data "aws_iam_policy_document" "dns_delegation_assume" {
  count = var.delegation_zone_name != "" ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.github_oidc.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for p in module.github_oidc.mgmt_sub_prefixes : "${p}:environment:*"]
    }
  }
}

data "aws_iam_policy_document" "dns_delegation" {
  count = var.delegation_zone_name != "" ? 1 : 0

  statement {
    sid       = "FindZone"
    actions   = ["route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadZone"
    actions   = ["route53:GetHostedZone", "route53:ListResourceRecordSets"]
    resources = [data.aws_route53_zone.delegation[0].arn]
  }

  statement {
    sid       = "WriteSubdomainNS"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.delegation[0].arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["NS"]
    }

    condition {
      test     = "ForAllValues:StringNotEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [local.delegation_zone, "${local.delegation_zone}."]
    }
  }

  statement {
    sid       = "WaitForChange"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }
}

resource "aws_iam_role" "dns_delegation" {
  count              = var.delegation_zone_name != "" ? 1 : 0
  name               = "${var.project_name}-dns-delegation"
  assume_role_policy = data.aws_iam_policy_document.dns_delegation_assume[0].json
}

resource "aws_iam_role_policy" "dns_delegation" {
  count  = var.delegation_zone_name != "" ? 1 : 0
  name   = "${var.project_name}-dns-delegation"
  role   = aws_iam_role.dns_delegation[0].id
  policy = data.aws_iam_policy_document.dns_delegation[0].json
}
