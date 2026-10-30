#!/usr/bin/env bash
#
# Publish infra/onboarding/connect-aws.yaml as connect-aws/<version>.yaml in a public
# S3 bucket, so onboarding links (onboarding-link.sh) can point at it. CloudFormation
# links only accept templates from S3, and the client's account reads it, so the
# objects under connect-aws/ are public (the template holds nothing secret; it's in
# this public repo). Nothing else in the bucket is.
#
# Run once per release, after the vX.Y.Z tag is pushed, from that tag's checkout.
# Published versions are never overwritten: links already sent keep working.
#
# Auth: your active AWS credentials, in the account that owns the bucket (portfolio).
# Creates the bucket if missing and reuses it if present.
#
# Usage:
#   AWS_PROFILE=derek infra/scripts/publish-onboarding-template.sh vX.Y.Z

set -euo pipefail

VERSION="${1:?usage: publish-onboarding-template.sh vX.Y.Z}"
[[ "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like v1.4.0" >&2; exit 1; }

TEMPLATE_BUCKET="${TEMPLATE_BUCKET:-website-deploy-templates-722647055695}"
REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../onboarding/connect-aws.yaml"
KEY="connect-aws/${VERSION}.yaml"

# The template must be the tagged one, not whatever is checked out.
TAG_SHA="$(git -C "${SCRIPT_DIR}" rev-parse -q --verify "refs/tags/${VERSION}^{commit}")" \
  || { echo "no tag ${VERSION} here (git fetch --tags?)" >&2; exit 1; }
if ! git -C "${SCRIPT_DIR}" diff --quiet "${TAG_SHA}" -- "${TEMPLATE}"; then
  echo "connect-aws.yaml differs from ${VERSION}; check out the tag first" >&2
  exit 1
fi

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "Account: ${ACCOUNT}   Bucket: ${TEMPLATE_BUCKET}   Key: ${KEY}"
[[ "${TEMPLATE_BUCKET}" == *"-${ACCOUNT}" ]] \
  || { echo "bucket ${TEMPLATE_BUCKET} isn't named for account ${ACCOUNT}; wrong profile, or set TEMPLATE_BUCKET" >&2; exit 1; }

aws cloudformation validate-template --region "${REGION}" \
  --template-body "file://${TEMPLATE}" >/dev/null
echo "Template: valid"

# --- Bucket: create if missing ------------------------------------------------
if aws s3api head-bucket --bucket "${TEMPLATE_BUCKET}" 2>/dev/null; then
  echo "Bucket: exists"
else
  echo "Bucket: creating"
  aws s3api create-bucket --bucket "${TEMPLATE_BUCKET}" --region "${REGION}" >/dev/null
  aws s3api put-bucket-versioning --bucket "${TEMPLATE_BUCKET}" \
    --versioning-configuration Status=Enabled
fi

# --- Public read for connect-aws/* only ----------------------------------------
# A public bucket policy needs BlockPublicPolicy off at the bucket AND the account.
ACCOUNT_BLOCK="$(aws s3control get-public-access-block --account-id "${ACCOUNT}" \
  --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text 2>/dev/null || echo False)"
if [ "${ACCOUNT_BLOCK}" = "True" ]; then
  echo "This account blocks public bucket policies (S3 → Block Public Access settings for this account)." >&2
  echo "Turn off the two 'bucket policies' settings there, or publish from another account (TEMPLATE_BUCKET)." >&2
  exit 1
fi
aws s3api put-public-access-block --bucket "${TEMPLATE_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
aws s3api put-bucket-policy --bucket "${TEMPLATE_BUCKET}" --policy "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicOnboardingTemplates",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${TEMPLATE_BUCKET}/connect-aws/*"
  }]
}
JSON
)"

# --- Upload, never overwrite ---------------------------------------------------
if aws s3api head-object --bucket "${TEMPLATE_BUCKET}" --key "${KEY}" >/dev/null 2>&1; then
  if aws s3 cp "s3://${TEMPLATE_BUCKET}/${KEY}" - | cmp -s - "${TEMPLATE}"; then
    echo "Already published, same content: nothing to do"
  else
    echo "${KEY} is already published with different content; versions aren't overwritten" >&2
    exit 1
  fi
else
  aws s3api put-object --bucket "${TEMPLATE_BUCKET}" --key "${KEY}" \
    --body "${TEMPLATE}" --content-type "text/yaml" >/dev/null
  echo "Published"
fi

echo
echo "https://${TEMPLATE_BUCKET}.s3.amazonaws.com/${KEY}"
echo "Links: infra/scripts/onboarding-link.sh --client <name> --version ${VERSION}"
