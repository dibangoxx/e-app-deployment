###############################################################################
# PILLAR 3 — Identity, SSO, Roles, MFA
# Cognito User Pool (customers), Cognito Identity Pool,
# IAM roles (admin/staff/partner/client), Secrets Manager rotation
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

###############################################################################
# Cognito User Pool — Customer identity with enforced MFA
###############################################################################

resource "aws_cognito_user_pool" "customers" {
  name = "flashinfo-customers-${var.environment}"

  mfa_configuration = var.mfa_enforcement

  software_token_mfa_configuration { enabled = true }

  password_policy {
    minimum_length                   = var.password_policy.minimum_length
    require_uppercase                = var.password_policy.require_uppercase
    require_lowercase                = var.password_policy.require_lowercase
    require_numbers                  = var.password_policy.require_numbers
    require_symbols                  = var.password_policy.require_symbols
    temporary_password_validity_days = 7
  }

  auto_verified_attributes = ["email"]

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
    invite_message_template {
      email_message = "Welcome to FlashInfo! Your username is {username} and temporary password is {####}."
      email_subject = "Welcome to FlashInfo"
      sms_message   = "FlashInfo user {username}, temp password: {####}"
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "email"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 255
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "role"
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 50
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "given_name"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  schema {
    attribute_data_type = "String"
    name                = "family_name"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
  }

  tags = { Name = "flashinfo-user-pool-${var.environment}" }
}

###############################################################################
# Cognito App Client — Web SPA (PKCE)
###############################################################################

resource "aws_cognito_user_pool_client" "web" {
  name         = "flashinfo-web-${var.environment}"
  user_pool_id = aws_cognito_user_pool.customers.id

  generate_secret                      = false
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH"
  ]

  callback_urls = [
    "https://${var.app_domain}/auth/callback",
    "https://${var.app_domain}/",
    "http://localhost:3000/auth/callback"
  ]

  logout_urls = [
    "https://${var.app_domain}/",
    "http://localhost:3000/"
  ]

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.customers.id
}

###############################################################################
# Cognito Identity Pool — AWS service access (S3 pre-signed, AppSync)
###############################################################################

resource "aws_cognito_identity_pool" "main" {
  identity_pool_name               = "flashinfo_${var.environment}"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.web.id
    provider_name           = aws_cognito_user_pool.customers.endpoint
    server_side_token_check = true
  }
}

###############################################################################
# IAM — ECS Task Execution Role
###############################################################################

resource "aws_iam_role" "ecs_execution" {
  name = "flashinfo-ecs-execution-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_basic" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "flashinfo-ecs-execution-secrets-${var.environment}"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# IAM — Application task roles (least privilege per service)
###############################################################################

resource "aws_iam_role" "api_task" {
  name = "flashinfo-api-task-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "api_task" {
  name = "flashinfo-api-task-policy-${var.environment}"
  role = aws_iam_role.api_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion"]
        Resource = "arn:aws:s3:::${var.documents_bucket_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.documents_bucket_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail", "ses:SendTemplatedEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution", "states:DescribeExecution"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = "*"
      }
    ]
  })
}

###############################################################################
# Secrets Manager — App secrets with rotation
###############################################################################

resource "aws_secretsmanager_secret" "app_secrets" {
  name        = "flashinfo/${var.environment}/app-config"
  description = "FlashInfo application configuration secrets"

  recovery_window_in_days = 30

  tags = { Name = "flashinfo-app-secrets-${var.environment}" }
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    jwt_signing_secret    = "CHANGE_ME_BEFORE_DEPLOY_${var.environment}"
    stripe_secret_key     = "CHANGE_ME_BEFORE_DEPLOY"
    stripe_webhook_secret = "CHANGE_ME_BEFORE_DEPLOY"
    sendgrid_api_key      = "CHANGE_ME_BEFORE_DEPLOY"
  })
  lifecycle { ignore_changes = [secret_string] }
}

###############################################################################
# Variables & Outputs
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
  type = string
}
variable "cognito_domain_prefix" {
  type = string
}
variable "ses_from_email" {
  type = string
}
variable "mfa_enforcement" {
  default = "ON"
}
variable "app_domain" {
  type = string
}
variable "documents_bucket_name" {
  default = ""
}
variable "password_policy" {
  type = object({
    minimum_length    = number
    require_uppercase = bool
    require_lowercase = bool
    require_numbers   = bool
    require_symbols   = bool
  })
}

output "user_pool_id" { value = aws_cognito_user_pool.customers.id }
output "user_pool_arn" { value = aws_cognito_user_pool.customers.arn }
output "user_pool_endpoint" { value = aws_cognito_user_pool.customers.endpoint }
output "user_pool_client_id" { value = aws_cognito_user_pool_client.web.id }
output "identity_pool_id" { value = aws_cognito_identity_pool.main.id }
output "ecs_execution_role_arn" { value = aws_iam_role.ecs_execution.arn }
output "api_task_role_arn" { value = aws_iam_role.api_task.arn }
output "app_secrets_arn" { value = aws_secretsmanager_secret.app_secrets.arn }
