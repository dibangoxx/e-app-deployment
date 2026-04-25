###############################################################################
# Root Variables
###############################################################################

variable "environment" {
  description = "Deployment environment"
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

variable "owner_team" {
  description = "Owning team email for cost tags"
  type        = string
}

variable "cost_center" {
  description = "Cost center code"
  type        = string
  default     = "engineering"
}

variable "org_management_email" {
  description = "AWS Organizations root email"
  type        = string
}

# ── Networking ──────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "domain_name" {
  description = "Primary domain e.g. flashinfo.example.com"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM cert ARN in primary region (for ALB)"
  type        = string
}

variable "acm_certificate_arn_us_east_1" {
  description = "ACM cert ARN in us-east-1 (for CloudFront)"
  type        = string
}

variable "waf_rate_limit" {
  description = "Max requests per 5 min per IP"
  type        = number
  default     = 2000
}

variable "allowed_admin_cidrs" {
  description = "CIDRs allowed through admin SG (VPN endpoints)"
  type        = list(string)
  default     = []
}

variable "alb_deletion_protection" {
  description = "Enable ALB deletion protection"
  type        = bool
  default     = true
}

# ── Identity ─────────────────────────────────────────────────────────────────
variable "cognito_domain_prefix" {
  type = string
}

variable "ses_from_email" {
  type = string
}

variable "ses_domain" {
  type = string
}

variable "password_policy" {
  type = object({
    minimum_length    = number
    require_uppercase = bool
    require_lowercase = bool
    require_numbers   = bool
    require_symbols   = bool
  })
  default = {
    minimum_length    = 12
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

# ── Runtime ──────────────────────────────────────────────────────────────────
variable "ecr_api_image" {
  description = "Full ECR URI for API container image"
  type        = string
}

variable "ecr_web_image" {
  description = "Full ECR URI for Web container image"
  type        = string
}

variable "api_task_cpu" {
  type    = number
  default = 512
}
variable "api_task_memory" {
  type    = number
  default = 1024
}
variable "web_task_cpu" {
  type    = number
  default = 256
}
variable "web_task_memory" {
  type    = number
  default = 512
}

# ── Data ─────────────────────────────────────────────────────────────────────
variable "db_name" {
  type    = string
  default = "flashinfo"
}
variable "db_master_username" {
  type    = string
  default = "hg_admin"
}
variable "db_instance_class" {
  type    = string
  default = "db.r6g.large"
}
variable "documents_bucket_name" { type = string }

# ── Landing Zone ─────────────────────────────────────────────────────────────
variable "cloudtrail_bucket_name" { type = string }
variable "log_retention_days" {
  type    = number
  default = 365
}
variable "backup_vault_name" {
  type    = string
  default = "flashinfo-vault"
}
variable "enable_guardduty" {
  type    = bool
  default = true
}
variable "enable_security_hub" {
  type    = bool
  default = true
}
variable "enable_aws_config" {
  type    = bool
  default = true
}
variable "enable_macie" {
  type    = bool
  default = true
}

# ── Analytics ────────────────────────────────────────────────────────────────
variable "quicksight_user_arn" {
  type    = string
  default = ""
}

# ── DevSecOps ────────────────────────────────────────────────────────────────
variable "ecr_api_repo_name" {
  type    = string
  default = "flashinfo-api"
}
variable "ecr_web_repo_name" {
  type    = string
  default = "flashinfo-web"
}
variable "github_repo" {
  type    = string
  default = "your-org/flashinfo"
}

# ── Alerting ─────────────────────────────────────────────────────────────────
variable "alert_email" { type = string }
