data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  full_name = "${var.name_prefix}-${var.name}"
}

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:AWS-managed encryption (no CMK by project decision).
  #checkov:skip=CKV_AWS_338:Short retention is intentional to control cost.
  name              = "/ecs/${local.full_name}"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------------------ IAM
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy protection: only tasks in THIS account may assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution role = what the ECS AGENT needs before your code runs:
# pull the image, create log streams, fetch this service's secrets.
resource "aws_iam_role" "execution" {
  name                 = "${local.full_name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0
  statement {
    actions   = ["ssm:GetParameters"]
    resources = values(var.secrets) # only this service's own parameters
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.secrets) > 0 ? 1 : 0
  name   = "read-own-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# Task role = what YOUR CODE (and the ADOT sidecar) may call at runtime.
resource "aws_iam_role" "task" {
  name                 = "${local.full_name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "task_base" {
  statement {
    sid = "XRayTraces"
    actions = [
      "xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules",
      "xray:GetSamplingTargets", "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "EcsExec"
    actions   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
    resources = ["*"]
  }
  statement {
    sid       = "AdotEmfLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ecs/application/metrics*"]
  }
}

resource "aws_iam_role_policy" "task_base" {
  name   = "tracing-and-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_base.json
}

resource "aws_iam_role_policy" "task_extra" {
  count  = var.attach_task_role_policy ? 1 : 0
  name   = "app-permissions"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# ------------------------------------------------------------------ network
resource "aws_security_group" "this" {
  name        = local.full_name
  description = "${var.name} tasks: inbound only from the ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = local.full_name }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.alb_security_group_id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  description                  = "App port from ALB only"
}

# Egress: HTTPS to AWS APIs/ECR (via NAT), plus DB/cache inside the VPC.
resource "aws_vpc_security_group_egress_rule" "all" {
  #checkov:skip=CKV_AWS_382:Tasks need HTTPS egress to AWS APIs (SSM, ECR, X-Ray); destination SGs restrict data ports.
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound (AWS APIs via NAT, data tier via SG rules)"
}

resource "aws_lb_target_group" "this" {
  #checkov:skip=CKV_AWS_378:ALB->task traffic stays inside the VPC on private subnets; TLS terminates at CloudFront.
  name                 = substr(local.full_name, 0, 32)
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip" # awsvpc networking: every task has its own ENI/IP
  vpc_id               = var.vpc_id
  deregistration_delay = 30 # in-flight requests drain 30 s, deploys stay fast

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = var.path_patterns
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.origin_verify_header_value]
    }
  }
}

# ------------------------------------------------------------------ task + service
resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: ~20% cheaper per vCPU-hour
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.image
      essential = true
      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]
      environment            = [for k, v in var.environment : { name = k, value = v }]
      secrets                = [for k, arn in var.secrets : { name = k, valueFrom = arn }]
      readonlyRootFilesystem = true
      mountPoints = [{
        sourceVolume  = "tmp"
        containerPath = "/tmp"
      }]
      user = "10001:10001"
      healthCheck = {
        command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health',timeout=2).status==200 else 1)"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      dependsOn   = [{ containerName = "otel-collector", condition = "START" }]
      stopTimeout = 25
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "app"
          mode                  = "non-blocking" # a CloudWatch hiccup must never freeze the app
          max-buffer-size       = "4m"
        }
      }
    },
    {
      name      = "otel-collector"
      image     = var.adot_image
      essential = false # tracing loss must not kill the business container
      command   = ["--config=/etc/ecs/ecs-default-config.yaml"]
      cpu       = 64
      memory    = 128
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "otel"
        }
      }
    }
  ])

  lifecycle {
    precondition {
      condition     = !endswith(var.image, ":none")
      error_message = "No image has been pushed for ${var.name} yet. Run the App CI/CD workflow once (it pushes images even when the environment is down), then apply again."
    }
  }
}

resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  enable_execute_command             = true
  health_check_grace_period_seconds  = var.health_check_grace_seconds
  deployment_minimum_healthy_percent = 100 # never drop below current capacity during a deploy
  deployment_maximum_percent         = 200
  propagate_tags                     = "SERVICE"
  wait_for_steady_state              = false

  deployment_circuit_breaker {
    enable   = true
    rollback = true # failed deploy -> automatic return to last healthy revision
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.this.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  lifecycle {
    # The app pipeline owns task definition revisions; autoscaling owns the count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.this]
}

# ------------------------------------------------------------------ autoscaling
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.full_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 120
    scale_out_cooldown = 30 # scale out fast (flash sales), scale in slowly
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
