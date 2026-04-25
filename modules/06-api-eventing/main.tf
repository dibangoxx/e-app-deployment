###############################################################################
# PILLAR 6 — API & Eventing
# EventBridge custom bus, SQS queues, Step Functions checkout workflow,
# Lambda async processors
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# EventBridge — custom bus for domain events
###############################################################################

resource "aws_cloudwatch_event_bus" "flashinfo" {
  name = "flashinfo-${var.environment}"
  tags = { Name = "flashinfo-event-bus-${var.environment}" }
}

resource "aws_cloudwatch_event_archive" "all_events" {
  name             = "flashinfo-archive-${var.environment}"
  event_source_arn = aws_cloudwatch_event_bus.flashinfo.arn
  retention_days   = 90
    description      = "All FlashInfo domain events - 90 day archive"
}

###############################################################################
# SQS Queues — order processing, notifications, inventory
###############################################################################

locals {
  queues = {
    order_dlq     = { name = "flashinfo-order-dlq-${var.environment}", retention = 1209600 }
    notif_dlq     = { name = "flashinfo-notif-dlq-${var.environment}", retention = 1209600 }
    inventory_dlq = { name = "flashinfo-inventory-dlq-${var.environment}", retention = 1209600 }
  }
}

resource "aws_sqs_queue" "order_dlq" {
  name                      = "flashinfo-order-dlq-${var.environment}"
  kms_master_key_id         = var.kms_key_arn
  message_retention_seconds = 1209600
  tags                      = { Name = "flashinfo-order-dlq-${var.environment}" }
}

resource "aws_sqs_queue" "order_processing" {
  name                       = "flashinfo-order-processing-${var.environment}"
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.order_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "flashinfo-order-queue-${var.environment}" }
}

resource "aws_sqs_queue" "notifications_dlq" {
  name              = "flashinfo-notif-dlq-${var.environment}"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sqs_queue" "notifications" {
  name                       = "flashinfo-notifications-${var.environment}"
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "flashinfo-notif-queue-${var.environment}" }
}

resource "aws_sqs_queue" "inventory_dlq" {
  name              = "flashinfo-inventory-dlq-${var.environment}"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sqs_queue" "inventory" {
  name                       = "flashinfo-inventory-${var.environment}"
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 120

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.inventory_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "flashinfo-inventory-queue-${var.environment}" }
}

###############################################################################
# EventBridge rules → SQS routing
###############################################################################

resource "aws_cloudwatch_event_rule" "order_placed" {
  name           = "flashinfo-order-placed-${var.environment}"
  event_bus_name = aws_cloudwatch_event_bus.flashinfo.name
  description    = "Route OrderPlaced events to processing queue"

  event_pattern = jsonencode({
    source      = ["flashinfo.orders"]
    detail-type = ["OrderPlaced", "OrderCancelled", "OrderRefundRequested"]
  })
}

resource "aws_cloudwatch_event_target" "order_to_sqs" {
  rule           = aws_cloudwatch_event_rule.order_placed.name
  event_bus_name = aws_cloudwatch_event_bus.flashinfo.name
  target_id      = "order-processing-sqs"
  arn            = aws_sqs_queue.order_processing.arn
}

resource "aws_sqs_queue_policy" "order_processing" {
  queue_url = aws_sqs_queue.order_processing.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.order_processing.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "document_uploaded" {
  name           = "flashinfo-document-uploaded-${var.environment}"
  event_bus_name = aws_cloudwatch_event_bus.flashinfo.name
  description    = "Route DocumentUploaded events"

  event_pattern = jsonencode({
    source      = ["flashinfo.documents"]
    detail-type = ["DocumentUploaded", "DocumentDeleted"]
  })
}

resource "aws_cloudwatch_event_rule" "notification_events" {
  name           = "flashinfo-notification-events-${var.environment}"
  event_bus_name = aws_cloudwatch_event_bus.flashinfo.name
  description    = "Route notification-triggering events"

  event_pattern = jsonencode({
    source      = ["flashinfo.orders", "flashinfo.shipping", "flashinfo.users"]
    detail-type = ["OrderShipped", "OrderDelivered", "PasswordChanged", "UserRegistered", "ReviewApproved"]
  })
}

resource "aws_cloudwatch_event_target" "notif_to_sqs" {
  rule           = aws_cloudwatch_event_rule.notification_events.name
  event_bus_name = aws_cloudwatch_event_bus.flashinfo.name
  target_id      = "notifications-sqs"
  arn            = aws_sqs_queue.notifications.arn
}

###############################################################################
# Step Functions — Checkout Workflow (cart → inventory → payment → confirm)
###############################################################################

resource "aws_iam_role" "step_functions" {
  name = "flashinfo-sfn-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  name = "flashinfo-sfn-policy-${var.environment}"
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = aws_cloudwatch_event_bus.flashinfo.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.order_processing.arn, aws_sqs_queue.notifications.arn]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutLogEvents",
        "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/flashinfo/step-functions/${var.environment}"
  retention_in_days = 30
}

resource "aws_sfn_state_machine" "checkout" {
  name     = "flashinfo-checkout-${var.environment}"
  role_arn = aws_iam_role.step_functions.arn

  logging_configuration {
    level                  = "ALL"
    include_execution_data = true
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
  }

  tracing_configuration { enabled = true }

  definition = jsonencode({
    Comment = "FlashInfo checkout: cart validation → inventory reserve → payment → order confirmation"
    StartAt = "ValidateCart"

    States = {

      ValidateCart = {
        Type     = "Task"
        Comment  = "Validate cart items are still available and prices are current"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = aws_sqs_queue.order_processing.url
          MessageBody = {
            action         = "VALIDATE_CART"
            "taskToken.$"  = "$$.Task.Token"
            "cartId.$"     = "$.cartId"
            "customerId.$" = "$.customerId"
          }
        }
        TimeoutSeconds   = 30
        HeartbeatSeconds = 20
        Catch = [{
          ErrorEquals = ["CartValidationError", "States.Timeout"]
          ResultPath  = "$.error"
          Next        = "CheckoutFailed"
        }]
        Next = "ReserveInventory"
      }

      ReserveInventory = {
        Type     = "Task"
        Comment  = "Soft-reserve inventory items for this order"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = aws_sqs_queue.inventory.url
          MessageBody = {
            action        = "RESERVE_INVENTORY"
            "taskToken.$" = "$$.Task.Token"
            "items.$"     = "$.items"
            "orderId.$"   = "$.orderId"
          }
        }
        TimeoutSeconds   = 60
        HeartbeatSeconds = 30
        Catch = [{
          ErrorEquals = ["InsufficientInventoryError", "States.Timeout"]
          ResultPath  = "$.error"
          Next        = "ReleaseInventory"
        }]
        Next = "ProcessPayment"
      }

      ProcessPayment = {
        Type     = "Task"
        Comment  = "Charge via Stripe, wait for confirmation"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = aws_sqs_queue.order_processing.url
          MessageBody = {
            action              = "PROCESS_PAYMENT"
            "taskToken.$"       = "$$.Task.Token"
            "orderId.$"         = "$.orderId"
            "paymentMethodId.$" = "$.paymentMethodId"
            "amount.$"          = "$.total"
          }
        }
        TimeoutSeconds   = 120
        HeartbeatSeconds = 60
        Catch = [{
          ErrorEquals = ["PaymentDeclinedError", "PaymentError", "States.Timeout"]
          ResultPath  = "$.error"
          Next        = "ReleaseInventory"
        }]
        Next = "ConfirmOrder"
      }

      ConfirmOrder = {
        Type     = "Task"
        Comment  = "Persist order, emit OrderPlaced event"
        Resource = "arn:aws:states:::events:putEvents"
        Parameters = {
          Entries = [{
            EventBusName  = aws_cloudwatch_event_bus.flashinfo.name
            Source        = "flashinfo.orders"
            "Detail-Type" = "OrderPlaced"
            "Detail.$"    = "States.JsonToString($)"
          }]
        }
        Next = "SendConfirmationEmail"
      }

      SendConfirmationEmail = {
        Type     = "Task"
        Comment  = "Queue confirmation email via notification service"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl = aws_sqs_queue.notifications.url
          MessageBody = {
            action         = "SEND_ORDER_CONFIRMATION"
            "orderId.$"    = "$.orderId"
            "customerId.$" = "$.customerId"
            "email.$"      = "$.customerEmail"
          }
        }
        Next = "CheckoutComplete"
      }

      CheckoutComplete = {
        Type    = "Succeed"
        Comment = "Order successfully placed"
      }

      ReleaseInventory = {
        Type     = "Task"
        Comment  = "Release soft-reserved inventory on failure"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl = aws_sqs_queue.inventory.url
          MessageBody = {
            action      = "RELEASE_INVENTORY"
            "orderId.$" = "$.orderId"
          }
        }
        Next = "CheckoutFailed"
      }

      CheckoutFailed = {
        Type  = "Fail"
        Error = "CheckoutError"
        Cause = "Checkout could not be completed — see error details"
      }
    }
  })

  tags = { Name = "flashinfo-checkout-sfn-${var.environment}" }
}

###############################################################################
# Lambda — DLQ monitor / alerting
###############################################################################

resource "aws_iam_role" "dlq_monitor" {
  name = "flashinfo-dlq-monitor-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "dlq_monitor" {
  name = "flashinfo-dlq-monitor-policy-${var.environment}"
  role = aws_iam_role.dlq_monitor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.order_dlq.arn, aws_sqs_queue.notifications_dlq.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

###############################################################################
# EventBridge Scheduler — health score recalculation (Pillar 10 integration)
###############################################################################

resource "aws_scheduler_schedule" "product_sync" {
  name = "flashinfo-product-sync-${var.environment}"

  flexible_time_window { mode = "OFF" }

  schedule_expression = "cron(0 2 * * ? *)"

  target {
    arn      = aws_sqs_queue.inventory.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      action = "NIGHTLY_INVENTORY_SYNC"
      source = "scheduler"
    })
  }
}

resource "aws_iam_role" "scheduler" {
  name = "flashinfo-scheduler-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "flashinfo-scheduler-policy-${var.environment}"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = "*"
    }]
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
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "kms_key_arn" {
  type = string
}
variable "aurora_cluster_arn" {
  type = string
}
variable "documents_bucket_arn" {
  type = string
}
variable "cognito_user_pool_arn" {
  type = string
}
variable "ses_from_email" {
  type = string
}

output "event_bus_name" { value = aws_cloudwatch_event_bus.flashinfo.name }
output "event_bus_arn" { value = aws_cloudwatch_event_bus.flashinfo.arn }
output "order_queue_url" { value = aws_sqs_queue.order_processing.url }
output "notifications_queue_url" { value = aws_sqs_queue.notifications.url }
output "inventory_queue_url" { value = aws_sqs_queue.inventory.url }
output "checkout_sfn_arn" { value = aws_sfn_state_machine.checkout.arn }
output "order_dlq_arn" { value = aws_sqs_queue.order_dlq.arn }
