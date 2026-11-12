resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enhanced" # per-task CPU/mem/network, restarts, deployments
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]
}

locals {
  secret_arn = { for k, p in aws_ssm_parameter.secret : k => p.arn }

  common_env = {
    ENVIRONMENT                 = var.environment
    AWS_REGION                  = local.region
    DB_HOST                     = aws_db_instance.this.address
    DB_PORT                     = tostring(aws_db_instance.this.port)
    DB_NAME                     = aws_db_instance.this.db_name
    DB_USER                     = aws_db_instance.this.username
    DB_SSLMODE                  = "verify-full" # TLS + certificate + hostname check against the RDS CA
    REDIS_URL                   = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379/0"
    COOKIE_SECURE               = "true"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4317"
    OTEL_TRACES_SAMPLER         = "parentbased_traceidratio"
    OTEL_TRACES_SAMPLER_ARG     = "0.2"
  }
  common_secrets = {
    DB_PASSWORD      = local.secret_arn["db_password"]
    JWT_SECRET       = local.secret_arn["jwt_secret"]
    REDIS_AUTH_TOKEN = local.secret_arn["cache_token"]
  }

  service_config = {
    identity = {
      paths    = ["/api/auth/*"]
      priority = 10 # more specific than /api/* so it must win
      env      = {}
      policy   = null
      attach   = false
    }
    ticketing = {
      paths    = ["/api/*"]
      priority = 20
      env = {
        ORDERS_QUEUE_URL = aws_sqs_queue.orders.url
        TICKETS_TABLE    = aws_dynamodb_table.tickets.name
      }
      policy = data.aws_iam_policy_document.ticketing.json
      attach = true
    }
  }
}

data "aws_iam_policy_document" "ticketing" {
  statement {
    sid       = "PublishOrderEvents"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.orders.arn]
  }
  statement {
    sid       = "ReadOwnTickets"
    actions   = ["dynamodb:Query", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.tickets.arn]
  }
}

module "svc" {
  source   = "../../modules/ecs-service"
  for_each = local.service_config

  name                       = each.key
  name_prefix                = local.name
  cluster_arn                = aws_ecs_cluster.this.arn
  cluster_name               = aws_ecs_cluster.this.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.app_subnet_ids
  image                      = "${data.aws_ecr_repository.svc[each.key].repository_url}:${nonsensitive(data.aws_ssm_parameter.image_tag[each.key].value)}"
  environment                = merge(local.common_env, { OTEL_SERVICE_NAME = each.key }, each.value.env)
  secrets                    = local.common_secrets
  alb_listener_arn           = aws_lb_listener.http.arn
  alb_security_group_id      = aws_security_group.alb.id
  path_patterns              = each.value.paths
  listener_priority          = each.value.priority
  origin_verify_header_value = random_password.origin_verify.result
  desired_count              = var.service_desired_count
  min_count                  = var.service_desired_count
  max_count                  = var.service_max_count
  log_retention_days         = var.log_retention_days
  attach_task_role_policy    = each.value.attach
  task_role_policy_json      = each.value.policy
  permissions_boundary_arn   = local.boundary
}
