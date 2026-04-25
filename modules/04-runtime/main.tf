###############################################################################
# PILLAR 4 — Application Runtime (ECS Fargate)
# Cluster, API service, Web service, ALB target groups, autoscaling
###############################################################################

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

###############################################################################
# ECS Cluster with Container Insights
###############################################################################

resource "aws_ecs_cluster" "main" {
  name = "flashinfo-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "flashinfo-cluster-${var.environment}" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

###############################################################################
# Security Group — ECS tasks
###############################################################################

resource "aws_security_group" "ecs" {
  name        = "flashinfo-ecs-${var.environment}"
  description = "ECS tasks - allow only from ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
    description     = "API port from ALB"
  }
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
    description     = "Web port from ALB"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "flashinfo-ecs-sg-${var.environment}" }
}

###############################################################################
# ALB Target Groups
###############################################################################

resource "aws_lb_target_group" "api" {
  name        = "flashinfo-api-${var.environment}"
  port        = 3001
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/health"
    timeout             = 10
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
  tags                 = { Name = "flashinfo-api-tg-${var.environment}" }
}

resource "aws_lb_target_group" "web" {
  name        = "flashinfo-web-${var.environment}"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    timeout             = 10
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
  tags                 = { Name = "flashinfo-web-tg-${var.environment}" }
}

###############################################################################
# Listener Rules
###############################################################################

resource "aws_lb_listener_rule" "api" {
  listener_arn = var.alb_listener_arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  condition {
    path_pattern { values = ["/api/*", "/health", "/api/v1/*"] }
  }
}

resource "aws_lb_listener_rule" "web" {
  listener_arn = var.alb_listener_arn
  priority     = 200
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
  condition {
    path_pattern { values = ["/*"] }
  }
}

###############################################################################
# Task Definitions
###############################################################################

resource "aws_ecs_task_definition" "api" {
  family                   = "flashinfo-api-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_execution_role_arn

  container_definitions = jsonencode([
    {
      name         = "api"
      image        = var.ecr_api_image
      essential    = true
      portMappings = [{ containerPort = 3001, protocol = "tcp" }]

      environment = [
        { name = "NODE_ENV", value = var.environment },
        { name = "PORT", value = "3001" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "COGNITO_USER_POOL_ID", value = var.cognito_user_pool_id },
        { name = "COGNITO_CLIENT_ID", value = var.cognito_client_id },
        { name = "REDIS_HOST", value = var.redis_endpoint },
        { name = "OPENSEARCH_HOST", value = "https://${var.opensearch_endpoint}" },
        { name = "DOCUMENTS_BUCKET", value = var.documents_bucket },
        { name = "EVENT_BUS_NAME", value = var.eventbridge_bus_name }
      ]

      secrets = [
        { name = "APP_SECRETS", valueFrom = var.secrets_arn },
        { name = "DB_SECRET", valueFrom = var.db_secret_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:3001/health || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }

      readonlyRootFilesystem = true
      user                   = "1000"

      linuxParameters = {
        initProcessEnabled = true
        capabilities = {
          drop = ["ALL"]
          add  = []
        }
      }
    }
  ])

  tags = { Name = "flashinfo-api-td-${var.environment}" }
}

resource "aws_ecs_task_definition" "web" {
  family                   = "flashinfo-web-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.web_cpu
  memory                   = var.web_memory
  execution_role_arn       = var.task_execution_role_arn

  container_definitions = jsonencode([
    {
      name         = "web"
      image        = var.ecr_web_image
      essential    = true
      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      environment = [
        { name = "NODE_ENV", value = var.environment },
        { name = "PORT", value = "3000" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "web"
        }
      }

      readonlyRootFilesystem = true
      user                   = "1000"
    }
  ])

  tags = { Name = "flashinfo-web-td-${var.environment}" }
}

###############################################################################
# ECS Services
###############################################################################

resource "aws_ecs_service" "api" {
  name                              = "flashinfo-api-${var.environment}"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 60
  enable_execute_command            = true
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3001
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller { type = "ECS" }

  lifecycle { ignore_changes = [task_definition, desired_count] }

  tags = { Name = "flashinfo-api-svc-${var.environment}" }
}

resource "aws_ecs_service" "web" {
  name                              = "flashinfo-web-${var.environment}"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.web.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 30
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 3000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle { ignore_changes = [task_definition, desired_count] }
  tags = { Name = "flashinfo-web-svc-${var.environment}" }
}

###############################################################################
# Auto Scaling — API service
###############################################################################

resource "aws_appautoscaling_target" "api" {
  max_capacity       = 20
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "flashinfo-api-cpu-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 65.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "api_memory" {
  name               = "flashinfo-api-memory-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
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
variable "alb_security_group_id" {
  type = string
}
variable "alb_listener_arn" {
  type = string
}
variable "ecr_api_image" {
  type = string
}
variable "ecr_web_image" {
  type = string
}
variable "api_cpu" {
  type    = number
  default = 512
}
variable "api_memory" {
  type    = number
  default = 1024
}
variable "web_cpu" {
  type    = number
  default = 256
}
variable "web_memory" {
  type    = number
  default = 512
}
variable "kms_key_arn" {
  type = string
}
variable "secrets_arn" {
  type = string
}
variable "log_group_name" {
  type = string
}
variable "task_execution_role_arn" {
  type = string
}
variable "cognito_user_pool_id" {
  type = string
}
variable "cognito_client_id" {
  type = string
}
variable "db_secret_arn" {
  type = string
}
variable "redis_endpoint" {
  type = string
}
variable "opensearch_endpoint" {
  type = string
}
variable "documents_bucket" {
  type = string
}
variable "eventbridge_bus_name" {
  type = string
}

output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "ecs_cluster_arn" { value = aws_ecs_cluster.main.arn }
output "api_service_name" { value = aws_ecs_service.api.name }
output "web_service_name" { value = aws_ecs_service.web.name }
output "ecs_security_group_id" { value = aws_security_group.ecs.id }
output "api_target_group_arn" { value = aws_lb_target_group.api.arn }
output "web_target_group_arn" { value = aws_lb_target_group.web.arn }
