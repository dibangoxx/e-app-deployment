###############################################################################
# PILLAR 10 — Analytics & Client Health Insights
# S3 data lake, Glue ETL (Aurora → S3 Parquet), Athena, QuickSight,
# Lambda health score job (login recency, orders, reviews)
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# S3 Data Lake
###############################################################################

resource "aws_s3_bucket" "data_lake" {
  bucket = "flashinfo-datalake-${var.environment}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "flashinfo-datalake-${var.environment}" }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "archive-raw-data"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }
}

###############################################################################
# Glue — ETL from Aurora to S3 Parquet
###############################################################################

resource "aws_glue_catalog_database" "flashinfo" {
  name        = var.glue_db_name
    description = "FlashInfo data catalog - products, orders, customers"
}

resource "aws_iam_role" "glue" {
  name = "flashinfo-glue-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_data" {
  name = "flashinfo-glue-data-${var.environment}"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.data_lake.arn, "${aws_s3_bucket.data_lake.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement"]
        Resource = var.aurora_cluster_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      }
    ]
  })
}

# Glue ETL jobs
resource "aws_glue_job" "orders_etl" {
  name         = "flashinfo-orders-etl-${var.environment}"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"

  command {
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/scripts/orders_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = ""
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.data_lake.bucket}/spark-logs/"
    "--TempDir"                          = "s3://${aws_s3_bucket.data_lake.bucket}/tmp/"
    "--OUTPUT_PATH"                      = "s3://${aws_s3_bucket.data_lake.bucket}/processed/orders/"
    "--ENVIRONMENT"                      = var.environment
  }

  number_of_workers = 2
  worker_type       = "G.1X"
  timeout           = 60
  max_retries       = 1

  tags = { Name = "flashinfo-orders-etl-${var.environment}" }
}

resource "aws_glue_job" "products_etl" {
  name         = "flashinfo-products-etl-${var.environment}"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"

  command {
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/scripts/products_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"        = "python"
    "--job-bookmark-option" = "job-bookmark-enable"
    "--enable-metrics"      = ""
    "--TempDir"             = "s3://${aws_s3_bucket.data_lake.bucket}/tmp/"
    "--OUTPUT_PATH"         = "s3://${aws_s3_bucket.data_lake.bucket}/processed/products/"
    "--ENVIRONMENT"         = var.environment
  }

  number_of_workers = 2
  worker_type       = "G.1X"
  timeout           = 30
}

# Nightly trigger
resource "aws_glue_trigger" "nightly_etl" {
  name     = "flashinfo-nightly-etl-${var.environment}"
  type     = "SCHEDULED"
  schedule = "cron(0 2 * * ? *)"

  actions {
    job_name = aws_glue_job.orders_etl.name
  }
  actions {
    job_name = aws_glue_job.products_etl.name
  }

  tags = { Name = "flashinfo-nightly-etl-${var.environment}" }
}

###############################################################################
# Glue Crawler
###############################################################################

resource "aws_glue_crawler" "data_lake" {
  name          = "flashinfo-crawler-${var.environment}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.flashinfo.name
  schedule      = "cron(30 2 * * ? *)"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/processed/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Name = "flashinfo-crawler-${var.environment}" }
}

###############################################################################
# Athena
###############################################################################

resource "aws_athena_workgroup" "flashinfo" {
  name = "flashinfo-${var.environment}"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824 # 1 GB safety cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.data_lake.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }

  tags = { Name = "flashinfo-athena-${var.environment}" }
}

# Saved Athena queries
resource "aws_athena_named_query" "top_products" {
  name        = "flashinfo-top-products-30d"
  workgroup   = aws_athena_workgroup.flashinfo.id
  database    = aws_glue_catalog_database.flashinfo.name
  description = "Top selling products last 30 days"

  query = <<-SQL
    SELECT
      p.name,
      p.category,
      SUM(oi.quantity) AS units_sold,
      SUM(oi.quantity * oi.unit_price) AS revenue,
      COUNT(DISTINCT o.customer_id) AS unique_buyers
    FROM processed.orders o
    JOIN processed.order_items oi ON o.id = oi.order_id
    JOIN processed.products p ON oi.product_id = p.id
    WHERE o.created_at >= DATE_ADD('day', -30, CURRENT_DATE)
      AND o.status IN ('delivered', 'shipped')
    GROUP BY p.name, p.category
    ORDER BY revenue DESC
    LIMIT 50;
  SQL
}

resource "aws_athena_named_query" "revenue_by_category" {
  name        = "flashinfo-revenue-by-category"
  workgroup   = aws_athena_workgroup.flashinfo.id
  database    = aws_glue_catalog_database.flashinfo.name
  description = "Monthly revenue breakdown by product category"

  query = <<-SQL
    SELECT
      DATE_TRUNC('month', o.created_at) AS month,
      p.category,
      COUNT(DISTINCT o.id) AS order_count,
      SUM(o.total) AS total_revenue,
      AVG(o.total) AS avg_order_value
    FROM processed.orders o
    JOIN processed.order_items oi ON o.id = oi.order_id
    JOIN processed.products p ON oi.product_id = p.id
    WHERE o.status != 'cancelled'
    GROUP BY 1, 2
    ORDER BY month DESC, total_revenue DESC;
  SQL
}

resource "aws_athena_named_query" "customer_cohorts" {
  name        = "flashinfo-customer-cohorts"
  workgroup   = aws_athena_workgroup.flashinfo.id
  database    = aws_glue_catalog_database.flashinfo.name
    description = "Customer cohort analysis - repeat purchase rates"

  query = <<-SQL
    WITH first_orders AS (
      SELECT customer_id, MIN(created_at) AS first_order_date
      FROM processed.orders
      WHERE status != 'cancelled'
      GROUP BY customer_id
    ),
    cohorts AS (
      SELECT
        DATE_TRUNC('month', fo.first_order_date) AS cohort_month,
        o.customer_id,
        DATE_DIFF('month', fo.first_order_date, o.created_at) AS months_since_first
      FROM processed.orders o
      JOIN first_orders fo ON o.customer_id = fo.customer_id
      WHERE o.status != 'cancelled'
    )
    SELECT
      cohort_month,
      months_since_first,
      COUNT(DISTINCT customer_id) AS customers
    FROM cohorts
    GROUP BY 1, 2
    ORDER BY cohort_month, months_since_first;
  SQL
}

###############################################################################
# Product Health Score Lambda (nightly)
###############################################################################

resource "aws_iam_role" "health_score" {
  name = "flashinfo-health-score-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "health_score" {
  name = "flashinfo-health-score-policy-${var.environment}"
  role = aws_iam_role.health_score.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["athena:StartQueryExecution", "athena:GetQueryExecution",
        "athena:GetQueryResults", "athena:StopQueryExecution"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.data_lake.arn, "${aws_s3_bucket.data_lake.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      }
    ]
  })
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
variable "aurora_cluster_arn" {
  type = string
}
variable "documents_bucket_name" {
  type = string
}
variable "kms_key_arn" {
  type = string
}
variable "quicksight_user_arn" {
  default = ""
}
variable "glue_db_name" {
  type = string
}

output "data_lake_bucket" { value = aws_s3_bucket.data_lake.id }
output "glue_database_name" { value = aws_glue_catalog_database.flashinfo.name }
output "athena_workgroup_name" { value = aws_athena_workgroup.flashinfo.name }
output "glue_role_arn" { value = aws_iam_role.glue.arn }
