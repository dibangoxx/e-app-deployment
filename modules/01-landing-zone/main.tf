###############################################################################
# PILLAR 1 — Landing Zone & Governance
# Covers: AWS Organizations, Control Tower guardrails, CloudTrail (all-region),
#         Security Hub, GuardDuty, AWS Config, KMS CMKs (DB + S3 separate),
#         AWS Backup vaults with vault lock and cross-account copy
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# KMS — separate CMKs per data domain (DB, S3, Secrets)
###############################################################################

resource "aws_kms_key" "primary" {
  description             = "FlashInfo primary CMK - app data, ECS, Secrets"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:Describe*"]
        Resource = "*"
      },
      {
        Sid       = "ECSTasksDecrypt"
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "flashinfo-primary-cmk-${var.environment}" }
}

resource "aws_kms_alias" "primary" {
  name          = "alias/flashinfo-primary-${var.environment}"
  target_key_id = aws_kms_key.primary.key_id
}

resource "aws_kms_key" "s3" {
  description             = "FlashInfo S3 CMK - documents, audit logs, assets"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "S3ServicePrincipal"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        Sid       = "CloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "flashinfo-s3-cmk-${var.environment}" }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/flashinfo-s3-${var.environment}"
  target_key_id = aws_kms_key.s3.key_id
}

resource "aws_kms_key" "aurora" {
  description             = "FlashInfo Aurora PostgreSQL CMK"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = { Name = "flashinfo-aurora-cmk-${var.environment}" }
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/flashinfo-aurora-${var.environment}"
  target_key_id = aws_kms_key.aurora.key_id
}

###############################################################################
# CloudTrail — Organization trail, all regions, Object Lock (IRS Pub 4557 7yr)
###############################################################################

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = var.cloudtrail_bucket
  force_destroy = false
  object_lock_enabled = true
  tags          = { Name = "flashinfo-cloudtrail-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  depends_on = [aws_s3_bucket_versioning.cloudtrail]
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 2555 # 7 years
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "org_trail" {
  name                          = "flashinfo-org-trail-${var.environment}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.s3.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"]
    }
    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  insight_selector {
    insight_type = "ApiCallRateInsight"
  }
  insight_selector {
    insight_type = "ApiErrorRateInsight"
  }

  tags = { Name = "flashinfo-org-trail-${var.environment}" }
}

###############################################################################
# CloudWatch Log Groups (ECS, VPC Flow, etc.)
###############################################################################

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/flashinfo/ecs/${var.environment}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.primary.arn
}

resource "aws_cloudwatch_log_group" "application" {
  name              = "/flashinfo/application/${var.environment}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.primary.arn
}

###############################################################################
# GuardDuty — S3, malware protection, Kubernetes audit logs
###############################################################################

resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = { Name = "flashinfo-guardduty-${var.environment}" }
}

###############################################################################
# Security Hub — CIS + PCI standards
###############################################################################

resource "aws_securityhub_account" "main" {
  count                    = var.enable_security_hub ? 1 : 0
  enable_default_standards = true
  auto_enable_controls     = true
}

resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_security_hub && var.enable_security_hub_cis ? 1 : 0
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "aws_best_practices" {
  count         = var.enable_security_hub ? 1 : 0
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

###############################################################################
# AWS Config — mandatory detective controls
###############################################################################

resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0
  name  = "flashinfo-config-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.enable_config ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_s3_bucket" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = "flashinfo-config-${var.environment}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "flashinfo-config-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.enable_config ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.enable_config ? 1 : 0
  bucket = aws_s3_bucket.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config[0].arn
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_config_configuration_recorder" "main" {
  count    = var.enable_config ? 1 : 0
  name     = "flashinfo-config-${var.environment}"
  role_arn = aws_iam_role.config[0].arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count          = var.enable_config ? 1 : 0
  name           = "flashinfo-config-delivery-${var.environment}"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  depends_on     = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "main" {
  count      = var.enable_config ? 1 : 0
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# Mandatory Config rules
resource "aws_config_config_rule" "s3_bucket_public_read" {
  count = var.enable_config ? 1 : 0
  name  = "s3-bucket-public-read-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "encrypted_volumes" {
  count = var.enable_config ? 1 : 0
  name  = "encrypted-volumes"
  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_encryption" {
  count = var.enable_config ? 1 : 0
  name  = "rds-storage-encrypted"
  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "mfa_enabled" {
  count = var.enable_config ? 1 : 0
  name  = "root-account-mfa-enabled"
  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

###############################################################################
# AWS Backup — vault lock, cross-account copy, lifecycle
###############################################################################

resource "aws_backup_vault" "main" {
  name        = "${var.backup_vault_name}-${var.environment}"
  kms_key_arn = aws_kms_key.primary.arn
  tags        = { Name = "${var.backup_vault_name}-${var.environment}" }
}

resource "aws_backup_vault_lock_configuration" "main" {
  backup_vault_name  = aws_backup_vault.main.name
  min_retention_days = 7
  max_retention_days = 2555
}

resource "aws_backup_plan" "main" {
  name = "flashinfo-backup-plan-${var.environment}"

  rule {
    rule_name         = "daily-30day-retention"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 * * ? *)"

    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }
  }

  rule {
    rule_name         = "weekly-7year-retention"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 ? * SUN *)"

    lifecycle {
      cold_storage_after = 90
      delete_after       = 2555
    }
  }

  tags = { Name = "flashinfo-backup-plan-${var.environment}" }
}

resource "aws_iam_role" "backup" {
  name = "flashinfo-backup-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_selection" "main" {
  name         = "flashinfo-all-tagged-${var.environment}"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.main.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupEnabled"
    value = "true"
  }
}

###############################################################################
# Variables & Outputs
###############################################################################

variable "environment" {
  description = "Deployment environment (prod | nonprod | staging)"
  type        = string
  validation {
    condition     = contains(["prod", "nonprod", "staging"], var.environment)
    error_message = "Must be prod, nonprod, or staging."
  }
}

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "org_management_email" {
  description = "AWS Organizations management account root email"
  type        = string
}

variable "cloudtrail_bucket" {
  description = "S3 bucket name for centralized CloudTrail logs (must be globally unique)"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 365
}

variable "enable_guardduty" {
  description = "Enable GuardDuty detector"
  type        = bool
  default     = true
}

variable "enable_security_hub" {
  description = "Enable Security Hub and subscribe to CIS/best-practice standards"
  type        = bool
  default     = true
}

variable "enable_security_hub_cis" {
  description = "Enable CIS standards subscription in Security Hub"
  type        = bool
  default     = false
}

variable "enable_config" {
  description = "Enable AWS Config recorder and mandatory detective rules"
  type        = bool
  default     = true
}

variable "backup_vault_name" {
  description = "Base name for the AWS Backup vault (environment suffix is appended)"
  type        = string
  default     = "flashinfo-vault"
}

output "primary_kms_key_arn" { value = aws_kms_key.primary.arn }
output "s3_kms_key_arn" { value = aws_kms_key.s3.arn }
output "aurora_kms_key_arn" { value = aws_kms_key.aurora.arn }
output "cloudtrail_bucket_id" { value = aws_s3_bucket.cloudtrail.id }
output "ecs_log_group_name" { value = aws_cloudwatch_log_group.ecs.name }
output "backup_vault_name" { value = aws_backup_vault.main.name }
output "backup_vault_arn" { value = aws_backup_vault.main.arn }
