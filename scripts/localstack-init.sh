#!/bin/bash
###############################################################################
# FlashInfo — LocalStack bootstrap
# Runs automatically when LocalStack is ready (via init hook)
# Creates all AWS resources the app expects, locally
###############################################################################

set -e
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=local
export AWS_SECRET_ACCESS_KEY=local
ENDPOINT=http://localhost:4566

echo "====================================================="
echo " FlashInfo LocalStack Init"
echo "====================================================="

# ─── S3 Buckets ──────────────────────────────────────────────────────────────
echo "[S3] Creating buckets..."

aws --endpoint-url=$ENDPOINT s3 mb s3://flashinfo-documents-local  --region us-east-1 2>/dev/null || true
aws --endpoint-url=$ENDPOINT s3 mb s3://flashinfo-assets-local     --region us-east-1 2>/dev/null || true
aws --endpoint-url=$ENDPOINT s3 mb s3://flashinfo-datalake-local   --region us-east-1 2>/dev/null || true

# Enable versioning on documents bucket
aws --endpoint-url=$ENDPOINT s3api put-bucket-versioning \
  --bucket flashinfo-documents-local \
  --versioning-configuration Status=Enabled

echo "[S3] Buckets ready ✓"

# ─── SQS Queues ──────────────────────────────────────────────────────────────
echo "[SQS] Creating queues..."

# Dead-letter queues first
aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-order-dlq-local \
  --attributes '{"MessageRetentionPeriod":"1209600"}' 2>/dev/null || true

aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-notif-dlq-local \
  --attributes '{"MessageRetentionPeriod":"1209600"}' 2>/dev/null || true

aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-inventory-dlq-local \
  --attributes '{"MessageRetentionPeriod":"1209600"}' 2>/dev/null || true

# Main queues
ORDER_DLQ_ARN=$(aws --endpoint-url=$ENDPOINT sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/flashinfo-order-dlq-local \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-order-processing-local \
  --attributes "{
    \"VisibilityTimeout\": \"300\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${ORDER_DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }" 2>/dev/null || true

aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-notifications-local \
  --attributes '{"VisibilityTimeout":"60"}' 2>/dev/null || true

aws --endpoint-url=$ENDPOINT sqs create-queue \
  --queue-name flashinfo-inventory-local \
  --attributes '{"VisibilityTimeout":"120"}' 2>/dev/null || true

echo "[SQS] Queues ready ✓"

# ─── EventBridge ─────────────────────────────────────────────────────────────
echo "[EventBridge] Creating event bus..."

aws --endpoint-url=$ENDPOINT events create-event-bus \
  --name flashinfo-local 2>/dev/null || true

echo "[EventBridge] Bus ready ✓"

# ─── Secrets Manager ─────────────────────────────────────────────────────────
echo "[Secrets] Creating app secrets..."

aws --endpoint-url=$ENDPOINT secretsmanager create-secret \
  --name "flashinfo/local/app-config" \
  --secret-string '{
    "jwt_signing_secret":    "flashinfo-local-dev-secret",
    "stripe_secret_key":     "sk_test_REPLACE_ME",
    "stripe_webhook_secret": "whsec_REPLACE_ME",
    "sendgrid_api_key":      "SG.REPLACE_ME"
  }' 2>/dev/null || true

aws --endpoint-url=$ENDPOINT secretsmanager create-secret \
  --name "flashinfo/local/aurora-master" \
  --secret-string '{
    "username": "flashinfo_admin",
    "password": "flashinfo_local_password",
    "host":     "postgres",
    "port":     5432,
    "dbname":   "flashinfo"
  }' 2>/dev/null || true

aws --endpoint-url=$ENDPOINT secretsmanager create-secret \
  --name "flashinfo/local/redis-auth-token" \
  --secret-string '{"auth_token":"flashinfo_redis_local"}' 2>/dev/null || true

echo "[Secrets] Secrets ready ✓"

# ─── KMS Keys ────────────────────────────────────────────────────────────────
echo "[KMS] Creating keys..."

aws --endpoint-url=$ENDPOINT kms create-key \
  --description "FlashInfo primary CMK — local" \
  --tags TagKey=Name,TagValue=flashinfo-primary-local 2>/dev/null || true

echo "[KMS] Keys ready ✓"

# ─── SES (verify test email) ─────────────────────────────────────────────────
echo "[SES] Verifying test sender..."

aws --endpoint-url=$ENDPOINT ses verify-email-identity \
  --email-address noreply@flashinfo.local 2>/dev/null || true

echo "[SES] Email ready ✓"

echo ""
echo "====================================================="
echo " LocalStack init complete!"
echo "  S3 buckets:    flashinfo-documents-local, -assets, -datalake"
echo "  SQS queues:    order-processing, notifications, inventory"
echo "  EventBridge:   flashinfo-local"
echo "  Secrets:       flashinfo/local/*"
echo "====================================================="
