###############################################################################
# PILLAR 11 — Security, Compliance & Audit
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

data "aws_caller_identity" "p11" {}

# IAM Access Analyzer
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "flashinfo-account-${var.environment}"
  type          = "ACCOUNT"
  tags          = { Name = "flashinfo-access-analyzer-${var.environment}" }
}

# CloudWatch metric filters + alarms for CIS baseline
locals {
  cis_alarms = {
    root_login = {
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      metric_name = "RootAccountLogins"
      description = "Root account login"
      threshold   = 1
    }
    unauthorized_api = {
      pattern     = "{ ($.errorCode = \"*UnauthorizedAccess*\") || ($.errorCode = \"AccessDenied\") }"
      metric_name = "UnauthorizedAPICalls"
      description = "Unauthorized API calls"
      threshold   = 10
    }
    mfa_console = {
      pattern     = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") }"
      metric_name = "MFADisabledConsoleLogins"
      description = "Console login without MFA"
      threshold   = 1
    }
    iam_policy_changes = {
      pattern     = "{ ($.eventName = \"DeleteGroupPolicy\") || ($.eventName = \"PutGroupPolicy\") || ($.eventName = \"AttachRolePolicy\") || ($.eventName = \"DetachRolePolicy\") }"
      metric_name = "IAMPolicyChanges"
      description = "IAM policy changes"
      threshold   = 1
    }
    kms_key_deletion = {
      pattern     = "{ ($.eventSource = \"kms.amazonaws.com\") && (($.eventName = \"DisableKey\") || ($.eventName = \"ScheduleKeyDeletion\")) }"
      metric_name = "KMSKeyDeletion"
      description = "KMS key disabled or scheduled for deletion"
      threshold   = 1
    }
    sg_changes = {
      pattern     = "{ ($.eventName = \"AuthorizeSecurityGroupIngress\") || ($.eventName = \"AuthorizeSecurityGroupEgress\") || ($.eventName = \"RevokeSecurityGroupIngress\") }"
      metric_name = "SecurityGroupChanges"
      description = "Security group changes"
      threshold   = 5
    }
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail_metrics" {
  name              = "/flashinfo/cloudtrail-metrics/${var.environment}"
  retention_in_days = 365
}

resource "aws_cloudwatch_log_metric_filter" "cis" {
  for_each = local.cis_alarms

  name           = "flashinfo-${each.key}-${var.environment}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail_metrics.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric_name
    namespace     = "FlashInfo/CISAlarms"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis" {
  for_each = local.cis_alarms

  alarm_name          = "flashinfo-cis-${each.key}-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = each.value.metric_name
  namespace           = "FlashInfo/CISAlarms"
  period              = 300
  statistic           = "Sum"
  threshold           = each.value.threshold
  alarm_description   = each.value.description
  alarm_actions       = [var.alert_topic_arn]
  treat_missing_data  = "notBreaching"
}

# WAF blocking spike alarm
resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  alarm_name          = "flashinfo-waf-block-spike-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = 500
    alarm_description   = "WAF blocking >500 requests per 5 min - possible attack"
  alarm_actions       = [var.alert_topic_arn]
}

# ALB 5xx alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "flashinfo-alb-5xx-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 50
  alarm_description   = "ALB returning >50 5xx errors per minute"
  alarm_actions       = [var.alert_topic_arn]
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
}

# GuardDuty high-severity findings
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name        = "flashinfo-guardduty-high-${var.environment}"
  description = "Capture GuardDuty HIGH severity findings"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_high.name
  target_id = "guardduty-sns"
  arn       = var.alert_topic_arn
}

output "access_analyzer_arn" { value = aws_accessanalyzer_analyzer.account.arn }


###############################################################################
# PILLAR 12 — DevSecOps & Operations
###############################################################################

# ECR Repositories
resource "aws_ecr_repository" "api" {
  name                 = var.ecr_api_repo_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
  tags = { Name = "flashinfo-api-ecr-${var.environment}" }
}

resource "aws_ecr_repository" "web" {
  name                 = var.ecr_web_repo_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
  tags = { Name = "flashinfo-web-ecr-${var.environment}" }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged prod images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["prod"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action       = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "web" {
  repository = aws_ecr_repository.web.name
  policy     = aws_ecr_lifecycle_policy.api.policy
}

# CodeBuild
resource "aws_s3_bucket" "artifacts" {
  bucket        = "flashinfo-artifacts-${var.environment}-${data.aws_caller_identity.p12.account_id}"
  force_destroy = true
  tags          = { Name = "flashinfo-artifacts-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "p12" {}

resource "aws_iam_role" "codebuild" {
  name = "flashinfo-codebuild-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "flashinfo-codebuild-policy-${var.environment}"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
                    "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
                    "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload", "ecr:PutImage"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_codebuild_project" "api" {
  name          = "flashinfo-api-build-${var.environment}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name = "ECR_REPO_URI"
      value = aws_ecr_repository.api.repository_url
    }
    environment_variable {
      name = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name = "ECS_CLUSTER"
      value = var.ecs_cluster_name
    }
    environment_variable {
      name = "ECS_SERVICE_NAME"
      value = var.ecs_api_service_name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
            - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
            - IMAGE_TAG=$ENVIRONMENT-$COMMIT_HASH-$(date +%Y%m%d%H%M%S)
        build:
          commands:
            - cd backend
            - docker build -t $ECR_REPO_URI:$IMAGE_TAG -t $ECR_REPO_URI:$ENVIRONMENT-latest .
            - docker run --rm $ECR_REPO_URI:$IMAGE_TAG npm test -- --ci
        post_build:
          commands:
            - docker push $ECR_REPO_URI:$IMAGE_TAG
            - docker push $ECR_REPO_URI:$ENVIRONMENT-latest
            - printf '[{"name":"api","imageUri":"%s"}]' "$ECR_REPO_URI:$IMAGE_TAG" > imagedefinitions.json
      artifacts:
        files:
          - backend/imagedefinitions.json
        discard-paths: yes
      cache:
        paths:
          - /root/.npm/**/*
    BUILDSPEC
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/flashinfo/codebuild/api-${var.environment}"
      stream_name = "builds"
    }
  }

  tags = { Name = "flashinfo-api-build-${var.environment}" }
}

resource "aws_codebuild_project" "web" {
  name          = "flashinfo-web-build-${var.environment}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name = "ECR_REPO_URI"
      value = aws_ecr_repository.web.repository_url
    }
    environment_variable {
      name = "ENVIRONMENT"
      value = var.environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
            - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
            - IMAGE_TAG=$ENVIRONMENT-$COMMIT_HASH-$(date +%Y%m%d%H%M%S)
        build:
          commands:
            - cd frontend
            - npm ci
            - npm test -- --watchAll=false --ci
            - npm run build
            - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
        post_build:
          commands:
            - docker push $ECR_REPO_URI:$IMAGE_TAG
            - printf '[{"name":"web","imageUri":"%s"}]' "$ECR_REPO_URI:$IMAGE_TAG" > imagedefinitions.json
      artifacts:
        files: [frontend/imagedefinitions.json]
        discard-paths: yes
      cache:
        paths: [frontend/node_modules/**/*]
    BUILDSPEC
  }

  tags = { Name = "flashinfo-web-build-${var.environment}" }
}

# CodePipeline
resource "aws_iam_role" "pipeline" {
  name = "flashinfo-pipeline-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = "flashinfo-pipeline-policy-${var.environment}"
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      {
        Effect = "Allow"
        Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecs:DescribeServices", "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks", "ecs:ListTasks", "ecs:RegisterTaskDefinition", "ecs:UpdateService"]
        Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.alert_topic_arn
      }
    ]
  })
}

resource "aws_codestarconnections_connection" "github" {
  name          = "flashinfo-github-${var.environment}"
  provider_type = "GitHub"
}

resource "aws_codepipeline" "main" {
  name     = "flashinfo-${var.environment}"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
    encryption_key {
      id   = var.kms_key_arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"
    action {
      name             = "GitHubSource"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "BuildAPI"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["source_output"]
      output_artifacts = ["api_build"]
      configuration    = { ProjectName = aws_codebuild_project.api.name }
    }
    action {
      name             = "BuildWeb"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      run_order        = 1
      input_artifacts  = ["source_output"]
      output_artifacts = ["web_build"]
      configuration    = { ProjectName = aws_codebuild_project.web.name }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "DeployAPI"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      run_order       = 1
      input_artifacts = ["api_build"]
      configuration = {
        ClusterName       = var.ecs_cluster_name
        ServiceName       = var.ecs_api_service_name
        FileName          = "imagedefinitions.json"
        DeploymentTimeout = "15"
      }
    }
    action {
      name            = "DeployWeb"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      run_order       = 1
      input_artifacts = ["web_build"]
      configuration = {
        ClusterName       = var.ecs_cluster_name
        ServiceName       = var.ecs_web_service_name
        FileName          = "imagedefinitions.json"
        DeploymentTimeout = "15"
      }
    }
  }

  tags = { Name = "flashinfo-pipeline-${var.environment}" }
}

# Inspector v2 — continuous ECR scanning
resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.p12.account_id]
  resource_types = ["ECR", "LAMBDA"]
}

# CloudWatch dashboard
resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "FlashInfo-${var.environment}-Ops"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ALB Requests And Error Counts"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ECS API CPU And Memory"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_api_service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_api_service_name]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ALB p99 Latency"
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "SQS — Order Queue Depth"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
             "QueueName", "flashinfo-order-processing-${var.environment}"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
             "QueueName", "flashinfo-order-dlq-${var.environment}"]
          ]
        }
      }
    ]
  })
}

###############################################################################
# Variables (all consolidated here)
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

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "primary_kms_key_arn" {
  type        = string
  description = "Primary KMS key ARN"
}

variable "cloudtrail_bucket" {
  type        = string
  description = "CloudTrail S3 bucket name"
}

variable "documents_bucket_id" {
  type        = string
  description = "Documents S3 bucket name"
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix for CloudWatch metrics"
}

variable "alert_topic_arn" {
  type        = string
  description = "SNS topic ARN for ops alerts"
}

variable "enable_shield" {
  type        = bool
  description = "Enable AWS Shield Advanced (prod only)"
  default     = false
}

variable "ecr_api_repo_name" {
  type        = string
  description = "ECR repository name for API image"
}

variable "ecr_web_repo_name" {
  type        = string
  description = "ECR repository name for Web image"
}

variable "ecs_cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "ecs_api_service_name" {
  type        = string
  description = "ECS API service name"
}

variable "ecs_web_service_name" {
  type        = string
  description = "ECS Web service name"
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for pipeline artifact encryption"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository (org/repo format)"
}

variable "github_branch" {
  type        = string
  description = "GitHub branch to deploy"
  default     = "main"
}

###############################################################################
# Outputs
###############################################################################

output "ecr_api_url"  { value = aws_ecr_repository.api.repository_url }
output "ecr_web_url"  { value = aws_ecr_repository.web.repository_url }
output "pipeline_arn" { value = aws_codepipeline.main.arn }
