###############################################################################
# FlashInfo E-Commerce — Root Terraform Configuration
###############################################################################

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    bucket         = "flashinfo-tfstate"
    key            = "platform/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "flashinfo-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "FlashInfo"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_team
      CostCenter  = var.cost_center
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "FlashInfo"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_team
      CostCenter  = var.cost_center
    }
  }
}

module "landing_zone" {
  source = "./modules/01-landing-zone"

  environment          = var.environment
  aws_region           = var.aws_region
  org_management_email = var.org_management_email
  cloudtrail_bucket    = var.cloudtrail_bucket_name
  log_retention_days   = var.log_retention_days
  enable_guardduty     = var.enable_guardduty
  enable_security_hub  = var.enable_security_hub
  enable_security_hub_cis = var.enable_security_hub_cis
  enable_config        = var.enable_aws_config
  backup_vault_name    = var.backup_vault_name
}

module "network" {
  source = "./modules/02-network"

  environment         = var.environment
  aws_region          = var.aws_region
  vpc_cidr            = var.vpc_cidr
  availability_zones  = var.availability_zones
  public_subnets      = var.public_subnet_cidrs
  private_subnets     = var.private_subnet_cidrs
  domain_name         = var.domain_name
  acm_certificate_arn = var.acm_certificate_arn
  waf_rate_limit      = var.waf_rate_limit
  allowed_admin_cidrs = var.allowed_admin_cidrs
  alb_deletion_protection = var.alb_deletion_protection
}

module "identity" {
  source = "./modules/03-identity"

  environment           = var.environment
  aws_region            = var.aws_region
  cognito_domain_prefix = var.cognito_domain_prefix
  ses_from_email        = var.ses_from_email
  mfa_enforcement       = "ON"
  app_domain            = var.domain_name
  password_policy       = var.password_policy
}

module "runtime" {
  source = "./modules/04-runtime"

  environment             = var.environment
  aws_region              = var.aws_region
  vpc_id                  = module.network.vpc_id
  private_subnet_ids      = module.network.private_subnet_ids
  alb_security_group_id   = module.network.alb_security_group_id
  alb_listener_arn        = module.network.alb_https_listener_arn
  enable_runtime_services = var.enable_runtime_services
  ecr_api_image           = var.ecr_api_image
  ecr_web_image           = var.ecr_web_image
  api_cpu                 = var.api_task_cpu
  api_memory              = var.api_task_memory
  web_cpu                 = var.web_task_cpu
  web_memory              = var.web_task_memory
  kms_key_arn             = module.landing_zone.primary_kms_key_arn
  secrets_arn             = module.identity.app_secrets_arn
  log_group_name          = module.landing_zone.ecs_log_group_name
  task_execution_role_arn = module.identity.ecs_execution_role_arn
  cognito_user_pool_id    = module.identity.user_pool_id
  cognito_client_id       = module.identity.user_pool_client_id
  db_secret_arn           = module.data.db_secret_arn
  redis_endpoint          = module.data.redis_primary_endpoint
  opensearch_endpoint     = module.data.opensearch_endpoint
  documents_bucket        = module.data.documents_bucket_name
  eventbridge_bus_name    = module.api_eventing.event_bus_name
}

module "data" {
  source = "./modules/05-data"

  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.runtime.ecs_security_group_id
  db_name               = var.db_name
  db_master_username    = var.db_master_username
  db_instance_class     = var.db_instance_class
  kms_key_arn           = module.landing_zone.primary_kms_key_arn
  s3_kms_key_arn        = module.landing_zone.s3_kms_key_arn
  documents_bucket_name = var.documents_bucket_name
  backup_vault_name     = module.landing_zone.backup_vault_name
}

module "api_eventing" {
  source = "./modules/06-api-eventing"

  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  kms_key_arn           = module.landing_zone.primary_kms_key_arn
  aurora_cluster_arn    = module.data.aurora_cluster_arn
  documents_bucket_arn  = module.data.documents_bucket_arn
  cognito_user_pool_arn = module.identity.user_pool_arn
  ses_from_email        = var.ses_from_email
}

module "frontend" {
  source    = "./modules/07-frontend"
  providers = { aws = aws.us_east_1 }

  environment         = var.environment
  domain_name         = var.domain_name
  acm_certificate_arn = var.acm_certificate_arn_us_east_1
  waf_rate_limit      = var.waf_rate_limit
  alb_dns_name        = module.network.alb_dns_name
  alb_origin_id       = "alb-api-origin"
}

module "messaging" {
  source = "./modules/09-messaging"

  environment         = var.environment
  aws_region          = var.aws_region
  ses_from_email      = var.ses_from_email
  ses_domain          = var.ses_domain
  kms_key_arn         = module.landing_zone.primary_kms_key_arn
  alert_email         = var.alert_email
  event_bus_name      = module.api_eventing.event_bus_name
  documents_bucket_id = module.data.documents_bucket_name
  enable_macie        = var.enable_macie
}

module "analytics" {
  source = "./modules/10-analytics"

  environment           = var.environment
  aws_region            = var.aws_region
  aurora_cluster_arn    = module.data.aurora_cluster_arn
  documents_bucket_name = module.data.documents_bucket_name
  kms_key_arn           = module.landing_zone.primary_kms_key_arn
  quicksight_user_arn   = var.quicksight_user_arn
  glue_db_name          = "flashinfo_${var.environment}"
}

module "devsecops" {
  source = "./modules/12-devsecops"

  environment          = var.environment
  aws_region           = var.aws_region
  vpc_id               = module.network.vpc_id
  primary_kms_key_arn  = module.landing_zone.primary_kms_key_arn
  cloudtrail_bucket    = var.cloudtrail_bucket_name
  documents_bucket_id  = module.data.documents_bucket_name
  alb_arn_suffix       = module.network.alb_arn_suffix
  alert_topic_arn      = module.messaging.ops_alert_topic_arn
  enable_shield        = var.environment == "prod" ? true : false
  ecr_api_repo_name    = var.ecr_api_repo_name
  ecr_web_repo_name    = var.ecr_web_repo_name
  ecs_cluster_name     = module.runtime.ecs_cluster_name
  ecs_api_service_name = module.runtime.api_service_name
  ecs_web_service_name = module.runtime.web_service_name
  kms_key_arn          = module.landing_zone.primary_kms_key_arn
  github_repo          = var.github_repo
  github_branch        = var.environment == "prod" ? "main" : "develop"
}