###############################################################################
# IAM — FlashInfo Terraform Deploy Policies
# Split into 4 managed policies to stay under the 6144-byte per-policy limit.
#
# Bootstrap with admin credentials (one-time):
#   terraform apply -lock=false -var-file=environments/prod/terraform.tfvars \
#     -target=aws_iam_user_policy_attachment.deploy_infra \
#     -target=aws_iam_user_policy_attachment.deploy_app \
#     -target=aws_iam_user_policy_attachment.deploy_analytics \
#     -target=aws_iam_user_policy_attachment.deploy_security
###############################################################################

locals {
  deploy_user_name = "NewTestDibang"
}

# ── 1. Infrastructure ────────────────────────────────────────────────────────
resource "aws_iam_policy" "deploy_infra" {
  name = "flashinfo-deploy-infra-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "IAM",  Effect = "Allow", Action = ["iam:*"],                                     Resource = "*" },
      { Sid = "KMS",  Effect = "Allow", Action = ["kms:*"],                                     Resource = "*" },
      { Sid = "S3",   Effect = "Allow", Action = ["s3:*"],                                      Resource = "*" },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:*"],                                    Resource = "*" },
      { Sid = "EC2",  Effect = "Allow", Action = ["ec2:*"],                                     Resource = "*" },
      { Sid = "ELB",  Effect = "Allow", Action = ["elasticloadbalancing:*"],                    Resource = "*" },
      { Sid = "WAF",  Effect = "Allow", Action = ["wafv2:*"],                                   Resource = "*" },
      { Sid = "CF",   Effect = "Allow", Action = ["cloudfront:*"],                              Resource = "*" },
      { Sid = "R53",  Effect = "Allow", Action = ["route53:*", "route53domains:*"],             Resource = "*" },
      { Sid = "ACM",  Effect = "Allow", Action = ["acm:*"],                                     Resource = "*" },
      { Sid = "CW",   Effect = "Allow", Action = ["cloudwatch:*", "application-autoscaling:*"], Resource = "*" },
      { Sid = "SSM",  Effect = "Allow", Action = ["ssm:*"],                                     Resource = "*" },
    ]
  })
}

# ── 2. Application services ───────────────────────────────────────────────────
resource "aws_iam_policy" "deploy_app" {
  name = "flashinfo-deploy-app-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Cognito",     Effect = "Allow", Action = ["cognito-idp:*", "cognito-identity:*"], Resource = "*" },
      { Sid = "Secrets",     Effect = "Allow", Action = ["secretsmanager:*"],                    Resource = "*" },
      { Sid = "ECS",         Effect = "Allow", Action = ["ecs:*", "ecr:*"],                      Resource = "*" },
      { Sid = "RDS",         Effect = "Allow", Action = ["rds:*"],                               Resource = "*" },
      { Sid = "ElastiCache", Effect = "Allow", Action = ["elasticache:*"],                       Resource = "*" },
      { Sid = "OpenSearch",  Effect = "Allow", Action = ["es:*", "opensearch:*"],                Resource = "*" },
      { Sid = "Events",      Effect = "Allow", Action = ["events:*", "states:*", "scheduler:*"], Resource = "*" },
      { Sid = "SES",         Effect = "Allow", Action = ["ses:*", "sesv2:*"],                    Resource = "*" },
      { Sid = "Messaging",   Effect = "Allow", Action = ["sns:*", "sqs:*"],                      Resource = "*" },
      { Sid = "Lambda",      Effect = "Allow", Action = ["lambda:*"],                            Resource = "*" },
    ]
  })
}

# ── 3. Analytics & CI/CD ─────────────────────────────────────────────────────
resource "aws_iam_policy" "deploy_analytics" {
  name = "flashinfo-deploy-analytics-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Glue",        Effect = "Allow", Action = ["glue:*"],                                        Resource = "*" },
      { Sid = "Athena",      Effect = "Allow", Action = ["athena:*"],                                      Resource = "*" },
      { Sid = "QS",          Effect = "Allow", Action = ["quicksight:*"],                                  Resource = "*" },
      { Sid = "Lake",        Effect = "Allow", Action = ["lakeformation:*"],                               Resource = "*" },
      { Sid = "CICD",        Effect = "Allow", Action = ["codepipeline:*", "codebuild:*", "codedeploy:*"], Resource = "*" },
      { Sid = "Connections", Effect = "Allow", Action = ["codestar-connections:*", "codeconnections:*"],   Resource = "*" },
      { Sid = "Backup",      Effect = "Allow", Action = ["backup:*", "backup-storage:*"],                  Resource = "*" },
      { Sid = "Orgs",        Effect = "Allow", Action = ["organizations:Describe*", "organizations:List*"], Resource = "*" },
    ]
  })
}

# ── 4. Security & governance ──────────────────────────────────────────────────
resource "aws_iam_policy" "deploy_security" {
  name = "flashinfo-deploy-security-${var.environment}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "GD",     Effect = "Allow", Action = ["guardduty:*"],       Resource = "*" },
      { Sid = "SH",     Effect = "Allow", Action = ["securityhub:*"],     Resource = "*" },
      { Sid = "Config", Effect = "Allow", Action = ["config:*"],          Resource = "*" },
      { Sid = "Macie",  Effect = "Allow", Action = ["macie2:*"],          Resource = "*" },
      { Sid = "AA",     Effect = "Allow", Action = ["access-analyzer:*"], Resource = "*" },
      { Sid = "Insp",   Effect = "Allow", Action = ["inspector2:*"],      Resource = "*" },
      { Sid = "CT",     Effect = "Allow", Action = ["cloudtrail:*"],      Resource = "*" },
      { Sid = "Shield", Effect = "Allow", Action = ["shield:*"],          Resource = "*" },
    ]
  })
}

# ── Attach all four policies to the deploy user ───────────────────────────────
resource "aws_iam_user_policy_attachment" "deploy_infra" {
  user       = local.deploy_user_name
  policy_arn = aws_iam_policy.deploy_infra.arn
}

resource "aws_iam_user_policy_attachment" "deploy_app" {
  user       = local.deploy_user_name
  policy_arn = aws_iam_policy.deploy_app.arn
}

resource "aws_iam_user_policy_attachment" "deploy_analytics" {
  user       = local.deploy_user_name
  policy_arn = aws_iam_policy.deploy_analytics.arn
}

resource "aws_iam_user_policy_attachment" "deploy_security" {
  user       = local.deploy_user_name
  policy_arn = aws_iam_policy.deploy_security.arn
}
