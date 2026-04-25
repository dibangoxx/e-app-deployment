###############################################################################
# PILLAR 5 — Data Layer
# Aurora PostgreSQL (Multi-AZ, PITR, encryption)
# S3 with Object Lock for documents
# ElastiCache Redis (sessions, cache, rate limiting)
# OpenSearch Service (product & order search)
###############################################################################

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

data "aws_caller_identity" "current" {}

###############################################################################
# Subnet Groups
###############################################################################

resource "aws_db_subnet_group" "aurora" {
  name       = "flashinfo-aurora-${var.environment}"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "flashinfo-aurora-subnet-${var.environment}" }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "flashinfo-redis-${var.environment}"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "flashinfo-redis-subnet-${var.environment}" }
}

###############################################################################
# Security Groups
###############################################################################

resource "aws_security_group" "aurora" {
  name        = "flashinfo-aurora-sg-${var.environment}"
  description = "Aurora - ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
    description     = "PostgreSQL from ECS"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "flashinfo-aurora-sg-${var.environment}" }
}

resource "aws_security_group" "redis" {
  name        = "flashinfo-redis-sg-${var.environment}"
  description = "Redis - ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
    description     = "Redis from ECS"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "flashinfo-redis-sg-${var.environment}" }
}

resource "aws_security_group" "opensearch" {
  name        = "flashinfo-opensearch-sg-${var.environment}"
  description = "OpenSearch - ECS tasks only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.ecs_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "flashinfo-opensearch-sg-${var.environment}" }
}

###############################################################################
# Aurora PostgreSQL Serverless v2 Cluster
###############################################################################

resource "random_password" "aurora_master" {
  length           = 32
  special          = true
  override_special = "!#$%&()-_=+[]<>:?"
}

resource "aws_secretsmanager_secret" "aurora" {
  name        = "flashinfo/${var.environment}/aurora-master"
  description = "Aurora PostgreSQL master credentials"
  kms_key_id  = var.kms_key_arn
  tags        = { Name = "flashinfo-aurora-secret-${var.environment}" }
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({
    username = var.db_master_username
    password = random_password.aurora_master.result
    engine   = "postgres"
    host     = aws_rds_cluster.aurora.endpoint
    port     = 5432
    dbname   = var.db_name
  })
}

resource "aws_rds_cluster_parameter_group" "aurora15" {
  name        = "flashinfo-aurora15-${var.environment}"
  family      = "aurora-postgresql15"
  description = "FlashInfo Aurora PostgreSQL 15 parameters"

  parameter {
    name  = "log_statement"
    value = "all"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  tags = { Name = "flashinfo-aurora-pg-${var.environment}" }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier              = "flashinfo-${var.environment}"
  engine                          = "aurora-postgresql"
  engine_version                  = "15.4"
  database_name                   = var.db_name
  master_username                 = var.db_master_username
  master_password                 = random_password.aurora_master.result
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora15.name
  storage_encrypted               = true
  kms_key_id                      = var.kms_key_arn
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "flashinfo-${var.environment}-final"
  backup_retention_period         = 35
  preferred_backup_window         = "03:00-04:00"
  preferred_maintenance_window    = "sun:04:00-sun:05:00"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  apply_immediately               = false
  copy_tags_to_snapshot           = true

  serverlessv2_scaling_configuration {
    min_capacity = var.environment == "prod" ? 1.0 : 0.5
    max_capacity = var.environment == "prod" ? 32.0 : 8.0
  }

  tags = {
    Name          = "flashinfo-aurora-${var.environment}"
    BackupEnabled = "true"
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "flashinfo-rds-monitoring-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_rds_cluster_instance" "writer" {
  identifier                            = "flashinfo-${var.environment}-writer"
  cluster_identifier                    = aws_rds_cluster.aurora.id
  instance_class                        = "db.serverless"
  engine                                = aws_rds_cluster.aurora.engine
  engine_version                        = aws_rds_cluster.aurora.engine_version
  db_subnet_group_name                  = aws_db_subnet_group.aurora.name
  publicly_accessible                   = false
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 731
  auto_minor_version_upgrade            = true
  copy_tags_to_snapshot                 = true
  tags                                  = { Name = "flashinfo-writer-${var.environment}" }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier                            = "flashinfo-${var.environment}-reader"
  cluster_identifier                    = aws_rds_cluster.aurora.id
  instance_class                        = "db.serverless"
  engine                                = aws_rds_cluster.aurora.engine
  engine_version                        = aws_rds_cluster.aurora.engine_version
  db_subnet_group_name                  = aws_db_subnet_group.aurora.name
  publicly_accessible                   = false
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = 731
  tags                                  = { Name = "flashinfo-reader-${var.environment}" }
}

###############################################################################
# S3 — Documents bucket with Object Lock & Macie-ready tagging
###############################################################################

resource "aws_s3_bucket" "documents" {
  bucket        = var.documents_bucket_name
  force_destroy = false
  tags = {
    Name          = "flashinfo-documents-${var.environment}"
    BackupEnabled = "true"
    DataClass     = "Sensitive"
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id
  rule {
    default_retention {
      mode  = "GOVERNANCE"
      years = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.s3_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket                  = aws_s3_bucket.documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "archive-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }
    noncurrent_version_expiration {
      noncurrent_days = 2555
    }
  }
}

resource "aws_s3_bucket_notification" "documents" {
  bucket      = aws_s3_bucket.documents.id
  eventbridge = true
}

# S3 Access Point for programmatic access
resource "aws_s3_access_point" "api" {
  bucket = aws_s3_bucket.documents.id
  name   = "flashinfo-api-${var.environment}"

  public_access_block_configuration {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

###############################################################################
# S3 — Static assets (product images, CSS, JS)
###############################################################################

resource "aws_s3_bucket" "assets" {
  bucket = "flashinfo-assets-${var.environment}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "flashinfo-assets-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# ElastiCache Redis — sessions, rate limiting, product cache
###############################################################################

resource "random_password" "redis_auth" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name        = "flashinfo/${var.environment}/redis-auth-token"
  description = "Redis AUTH token"
  kms_key_id  = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = jsonencode({ auth_token = random_password.redis_auth.result })
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "flashinfo-${var.environment}"
  description                = "FlashInfo Redis - sessions and cache"
  node_type                  = var.environment == "prod" ? "cache.r7g.large" : "cache.t4g.medium"
  port                       = 6379
  num_cache_clusters         = var.environment == "prod" ? 3 : 1
  automatic_failover_enabled = var.environment == "prod"
  multi_az_enabled           = var.environment == "prod"
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  snapshot_retention_limit   = 7
  snapshot_window            = "03:00-04:00"
  maintenance_window         = "sun:05:00-sun:06:00"
  auto_minor_version_upgrade = true
  engine_version             = "7.1"

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  tags = { Name = "flashinfo-redis-${var.environment}" }
}

resource "aws_cloudwatch_log_group" "redis" {
  name              = "/flashinfo/redis/${var.environment}"
  retention_in_days = 30
}

###############################################################################
# OpenSearch — product & order search
###############################################################################

resource "random_password" "opensearch_master" {
  length      = 16
  special     = true
  min_special = 2
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_secretsmanager_secret" "opensearch" {
  name        = "flashinfo/${var.environment}/opensearch-master"
  description = "OpenSearch master credentials"
  kms_key_id  = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "opensearch" {
  secret_id = aws_secretsmanager_secret.opensearch.id
  secret_string = jsonencode({
    username = "flashinfo-admin"
    password = random_password.opensearch_master.result
  })
}

resource "aws_opensearch_domain" "search" {
  domain_name    = "flashinfo-${var.environment}"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type            = var.environment == "prod" ? "r6g.large.search" : "t3.small.search"
    instance_count           = var.environment == "prod" ? 3 : 1
    zone_awareness_enabled   = var.environment == "prod"
    dedicated_master_enabled = var.environment == "prod"
    dedicated_master_type    = var.environment == "prod" ? "r6g.large.search" : null
    dedicated_master_count   = var.environment == "prod" ? 3 : null

    dynamic "zone_awareness_config" {
      for_each = var.environment == "prod" ? [1] : []
      content { availability_zone_count = 3 }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.environment == "prod" ? 100 : 20
    throughput  = 250
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = var.kms_key_arn
  }

  node_to_node_encryption { enabled = true }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = true
    master_user_options {
      master_user_name     = "flashinfo-admin"
      master_user_password = random_password.opensearch_master.result
    }
  }

  vpc_options {
    subnet_ids         = [var.private_subnet_ids[0]]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  tags = { Name = "flashinfo-opensearch-${var.environment}" }
}

resource "aws_cloudwatch_log_group" "opensearch" {
  name              = "/flashinfo/opensearch/${var.environment}"
  retention_in_days = 30
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
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "ecs_security_group_id" {
  type = string
}
variable "db_name" {
  default = "flashinfo"
}
variable "db_master_username" {
  default = "hg_admin"
}
variable "db_instance_class" {
  default = "db.r6g.large"
}
variable "kms_key_arn" {
  type = string
}
variable "s3_kms_key_arn" {
  type = string
}
variable "documents_bucket_name" {
  type = string
}
variable "backup_vault_name" {
  type = string
}

output "aurora_cluster_arn" { value = aws_rds_cluster.aurora.arn }
output "aurora_cluster_endpoint" { value = aws_rds_cluster.aurora.endpoint }
output "aurora_reader_endpoint" { value = aws_rds_cluster.aurora.reader_endpoint }
output "aurora_sg_id" { value = aws_security_group.aurora.id }
output "db_secret_arn" { value = aws_secretsmanager_secret.aurora.arn }
output "documents_bucket_name" { value = aws_s3_bucket.documents.id }
output "documents_bucket_arn" { value = aws_s3_bucket.documents.arn }
output "assets_bucket_name" { value = aws_s3_bucket.assets.id }
output "redis_primary_endpoint" { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "opensearch_endpoint" { value = aws_opensearch_domain.search.endpoint }
