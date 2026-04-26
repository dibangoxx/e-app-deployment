#!/usr/bin/env bash
set -euo pipefail

# Idempotent bootstrap for Terraform remote state backend.
# Usage:
#   ./scripts/bootstrap-terraform-backend.sh [bucket_name] [lock_table_name] [region]

BUCKET_NAME="${1:-flashinfo-tfstate}"
LOCK_TABLE_NAME="${2:-flashinfo-tfstate-lock}"
REGION="${3:-us-east-1}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed." >&2
    exit 1
  fi
}

require_cmd aws

print_permission_help() {
  cat <<EOF

Permission error while creating/checking backend resources.
Request an admin to grant these minimum permissions in region ${REGION}:

- s3:CreateBucket
- s3:HeadBucket
- s3:PutBucketVersioning
- s3:PutBucketEncryption
- dynamodb:DescribeTable
- dynamodb:CreateTable
- dynamodb:UpdateTable
- dynamodb:DescribeTimeToLive
- dynamodb:UpdateTimeToLive

Target resources:
- arn:aws:s3:::${BUCKET_NAME}
- arn:aws:s3:::${BUCKET_NAME}/*
- arn:aws:dynamodb:${REGION}:<account-id>:table/${LOCK_TABLE_NAME}

After permissions are updated, re-run:
  ./scripts/bootstrap-terraform-backend.sh ${BUCKET_NAME} ${LOCK_TABLE_NAME} ${REGION}
EOF
}

echo "Using backend bucket: ${BUCKET_NAME}"
echo "Using lock table:    ${LOCK_TABLE_NAME}"
echo "Using region:        ${REGION}"

echo "Checking AWS identity..."
aws sts get-caller-identity --output table >/dev/null

echo "Ensuring S3 backend bucket exists..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" >/dev/null 2>&1; then
  echo "Bucket already exists: ${BUCKET_NAME}"
else
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  echo "Created bucket: ${BUCKET_NAME}"
fi

echo "Enabling bucket versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "Enforcing bucket encryption (SSE-S3)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "Ensuring DynamoDB lock table exists..."
if aws dynamodb describe-table --table-name "${LOCK_TABLE_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Lock table already exists: ${LOCK_TABLE_NAME}"
else
  if ! aws dynamodb create-table \
    --table-name "${LOCK_TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" >/dev/null; then
    print_permission_help
    exit 1
  fi

  aws dynamodb wait table-exists \
    --table-name "${LOCK_TABLE_NAME}" \
    --region "${REGION}"

  echo "Created lock table: ${LOCK_TABLE_NAME}"
fi

echo "Terraform backend bootstrap complete."
echo "Next steps:"
echo "  1) cd terraform"
echo "  2) terraform init"
echo "  3) terraform plan -var-file=environments/prod/terraform.tfvars"
