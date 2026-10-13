#!/usr/bin/env bash
#
# Create the Terraform state backend (S3 bucket, plus a DynamoDB lock table if
# you name one) in the CURRENT AWS account. Run this ONCE per new account, before `terraform init`,
# because an S3 backend can't bootstrap the bucket it stores state in.
#
# Auth: uses your active AWS credentials/profile — for a client, the one-time
# admin/SSO access they grant for bootstrap. Set AWS_PROFILE first.
#
# Usage:
#   AWS_PROFILE=client-bootstrap \
#     infra/scripts/bootstrap-backend.sh <state-bucket> [<lock-table>|""] [region]
#
# New clients don't need a lock table: state is locked with an S3 lockfile
# (use_lockfile). Pass "" for it; the table is only for clients still on
# `state_lock: dynamodb` / `both` (clients/README.md).

set -euo pipefail

BUCKET="${1:?usage: bootstrap-backend.sh <state-bucket> [<lock-table>|\"\"] [region]}"
TABLE="${2:-}"
REGION="${3:-us-west-2}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "Account: ${ACCOUNT}   Region: ${REGION}"
echo "Bucket:  ${BUCKET}"
echo "Table:   ${TABLE:-none (S3 lockfile)}"
echo

# --- S3 state bucket: versioned, encrypted, fully private --------------------
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "bucket ${BUCKET} already exists — skipping"
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "${BUCKET}" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "${BUCKET}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "${BUCKET}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "created bucket ${BUCKET}"
fi

# --- DynamoDB lock table (only if named) ------------------------------------
if [ -z "${TABLE}" ]; then
  echo "no lock table — state is locked with an S3 lockfile"
elif aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "table ${TABLE} already exists — skipping"
else
  aws dynamodb create-table --table-name "${TABLE}" --region "${REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
  echo "created table ${TABLE}"
fi

echo
echo "Backend ready (${BUCKET}${TABLE:+ / ${TABLE}} in ${REGION}). If the bucket isn't"
echo "the <name>-tf-state default, set state_bucket in clients/<name>.yaml."
