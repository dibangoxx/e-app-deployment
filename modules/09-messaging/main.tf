###############################################################################
# MODULE: Documents + Messaging (Pillars 8 & 9)
# Single terraform block, all variables deduplicated
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# PILLAR 8 — Documents & Records (Macie, pre-signed URL role)
###############################################################################

resource "aws_macie2_account" "main" {
  count                        = var.enable_macie ? 1 : 0
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

resource "aws_macie2_classification_job" "documents" {
  count      = var.enable_macie ? 1 : 0
  job_type   = "SCHEDULED"
  name       = "flashinfo-docs-scan-${var.environment}"
  depends_on = [aws_macie2_account.main]

  schedule_frequency {
    weekly_schedule = "MONDAY"
  }

  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [var.documents_bucket_id]
    }
  }
}

resource "aws_iam_role" "presign_lambda" {
  name = "flashinfo-presign-lambda-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "presign_lambda" {
  name = "flashinfo-presign-policy-${var.environment}"
  role = aws_iam_role.presign_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.documents_bucket_id}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

###############################################################################
# PILLAR 9 — Messaging, Notifications & Email
###############################################################################

resource "aws_ses_domain_identity" "main" {
  domain = var.ses_domain
}

resource "aws_ses_domain_dkim" "main" {
  domain = aws_ses_domain_identity.main.domain
}

resource "aws_ses_configuration_set" "main" {
  name                       = "flashinfo-${var.environment}"
  reputation_metrics_enabled = true
  sending_enabled            = true
}

resource "aws_ses_template" "order_confirmation" {
  name    = "flashinfo-order-confirmation-${var.environment}"
  subject = "Your FlashInfo order {{orderId}} is confirmed!"

  html = "<h1>Thank you for your order!</h1><p>Order #{{orderId}} Total: $${{total}}</p>"

  text = "Thank you! Order #{{orderId}} Total: $${{total}}"
}

resource "aws_ses_template" "shipping_confirmation" {
  name    = "flashinfo-shipping-confirmation-${var.environment}"
  subject = "Your FlashInfo order {{orderId}} has shipped!"

  html = "<h1>Your order is on its way!</h1><p>Tracking: {{trackingNumber}}</p>"

  text = "Your order shipped! Tracking: {{trackingNumber}}"
}

resource "aws_ses_template" "password_reset" {
  name    = "flashinfo-password-reset-${var.environment}"
  subject = "Reset your FlashInfo password"

  html = "<h1>Password Reset</h1><p><a href='{{resetLink}}'>Reset password</a></p>"

  text = "Reset your password: {{resetLink}}"
}

resource "aws_sns_topic" "ops_alerts" {
  name              = "flashinfo-ops-alerts-${var.environment}"
  kms_master_key_id = var.kms_key_arn
  tags              = { Name = "flashinfo-ops-alerts-${var.environment}" }
}

resource "aws_sns_topic" "order_events" {
  name              = "flashinfo-order-events-${var.environment}"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic" "inventory_alerts" {
  name              = "flashinfo-inventory-alerts-${var.environment}"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# Variables (single deduplicated block)
###############################################################################

variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["prod", "nonprod", "staging"], var.environment)
    error_message = "environment must be prod, nonprod, or staging."
  }
}

variable "aws_region" {
  type        = string
  description = "Primary AWS region"
}

variable "documents_bucket_id" {
  type        = string
  description = "S3 documents bucket name"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for encryption"
}

variable "event_bus_name" {
  type        = string
  description = "EventBridge custom bus name"
}

variable "enable_macie" {
  type        = bool
  description = "Enable Macie scanning on documents bucket"
  default     = true
}

variable "ses_from_email" {
  type        = string
  description = "Verified SES sender email"
}

variable "ses_domain" {
  type        = string
  description = "SES verified domain"
}

variable "alert_email" {
  type        = string
  description = "Ops alert subscription email"
}

###############################################################################
# Outputs
###############################################################################

output "presign_lambda_role_arn"    { value = aws_iam_role.presign_lambda.arn }
output "ops_alert_topic_arn"        { value = aws_sns_topic.ops_alerts.arn }
output "order_events_topic_arn"     { value = aws_sns_topic.order_events.arn }
output "inventory_alerts_topic_arn" { value = aws_sns_topic.inventory_alerts.arn }
output "ses_domain_verification"    { value = aws_ses_domain_identity.main.verification_token }
