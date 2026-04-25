###############################################################################
# PILLAR 2 — Network & Perimeter
# VPC (3 AZs), Client VPN, CloudFront → WAF → ALB, Route53, Flow Logs
###############################################################################

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# VPC & Subnets
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "flashinfo-vpc-${var.environment}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "flashinfo-igw-${var.environment}" }
}

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "flashinfo-public-${var.availability_zones[count.index]}-${var.environment}" }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = { Name = "flashinfo-private-${var.availability_zones[count.index]}-${var.environment}" }
}

resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"
  tags   = { Name = "flashinfo-nat-eip-${count.index}-${var.environment}" }
}

resource "aws_nat_gateway" "main" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "flashinfo-nat-${count.index}-${var.environment}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "flashinfo-public-rt-${var.environment}" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = { Name = "flashinfo-private-rt-${count.index}-${var.environment}" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# VPC Flow Logs
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/flashinfo/vpc-flow-logs/${var.environment}"
  retention_in_days = 90
}

resource "aws_iam_role" "flow_logs" {
  name = "flashinfo-flow-logs-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "flashinfo-flow-logs-${var.environment}"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["logs:CreateLogGroup", "logs:CreateLogStream",
                "logs:PutLogEvents", "logs:DescribeLogGroups",
                "logs:DescribeLogStreams"]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
}

###############################################################################
# Security Groups
###############################################################################

resource "aws_security_group" "alb" {
  name        = "flashinfo-alb-sg-${var.environment}"
  description = "ALB - HTTPS from CloudFront + HTTP redirect"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from CloudFront"
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP redirect"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "flashinfo-alb-sg-${var.environment}" }
}

###############################################################################
# ALB + Access Logs bucket
###############################################################################

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "flashinfo-alb-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "flashinfo-alb-logs-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB access logs require the regional ELB service account to have s3:PutObject
# ELB account IDs per region: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
locals {
  elb_account_ids = {
    "us-east-1"      = "127311923021"
    "us-east-2"      = "033677994240"
    "us-west-1"      = "027434742980"
    "us-west-2"      = "797873946194"
    "eu-west-1"      = "156460612806"
    "eu-central-1"   = "054676820928"
    "ap-southeast-1" = "114774131450"
    "ap-southeast-2" = "783225319266"
    "ap-northeast-1" = "582318560864"
  }
  elb_account_id = lookup(local.elb_account_ids, var.aws_region, "127311923021")
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowELBLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.elb_account_id}:root" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "AllowDeliveryLogsServiceCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.alb_logs.arn
      },
      {
        Sid       = "AllowDeliveryLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_lb" "main" {
  depends_on = [aws_s3_bucket_policy.alb_logs]
  name               = "flashinfo-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection       = var.alb_deletion_protection
  drop_invalid_header_fields       = true
  enable_cross_zone_load_balancing = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "flashinfo-alb-${var.environment}" }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

###############################################################################
# WAF v2 — Regional (for ALB) + CloudFront scope
###############################################################################

resource "aws_wafv2_web_acl" "alb" {
  name  = "flashinfo-waf-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "FlashInfoWAF"
    sampled_requests_enabled   = true
  }

  # AWS Managed rules
  dynamic "rule" {
    for_each = {
      "CommonRuleSet"           = { name = "AWSManagedRulesCommonRuleSet",          priority = 10 }
      "KnownBadInputs"          = { name = "AWSManagedRulesKnownBadInputsRuleSet",  priority = 20 }
      "SQLiRuleSet"             = { name = "AWSManagedRulesSQLiRuleSet",            priority = 30 }
      "LinuxRuleSet"            = { name = "AWSManagedRulesLinuxRuleSet",           priority = 40 }
      "IPReputationList"        = { name = "AWSManagedRulesAmazonIpReputationList", priority = 50 }
    }
    content {
      name     = rule.key
      priority = rule.value.priority
      override_action {
    none {}
  }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 60
    action { 
      block {} 
      }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  tags = { Name = "flashinfo-waf-${var.environment}" }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.alb.arn
}

# WAF logging
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-flashinfo-${var.environment}"
  retention_in_days = 90
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.alb.arn
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
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "availability_zones" {
  type = list(string)
}
variable "public_subnets" {
  type = list(string)
}
variable "private_subnets" {
  type = list(string)
}
variable "domain_name" {
  type = string
}
variable "acm_certificate_arn" {
  type = string
}
variable "waf_rate_limit"     {
  type = number
  default = 2000
}
variable "allowed_admin_cidrs" {
  type = list(string)
  default = []
}
variable "alb_deletion_protection" {
  type        = bool
  description = "Whether ALB deletion protection is enabled"
  default     = true
}

output "vpc_id"                   { value = aws_vpc.main.id }
output "public_subnet_ids"        { value = aws_subnet.public[*].id }
output "private_subnet_ids"       { value = aws_subnet.private[*].id }
output "alb_security_group_id"    { value = aws_security_group.alb.id }
output "alb_https_listener_arn"   { value = aws_lb_listener.https.arn }
output "alb_dns_name"             { value = aws_lb.main.dns_name }
output "alb_arn_suffix"           { value = aws_lb.main.arn_suffix }
output "waf_alb_arn"              { value = aws_wafv2_web_acl.alb.arn }
