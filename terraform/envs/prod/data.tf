# ======================================================= RDS PostgreSQL
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.network.data_subnet_ids # isolated tier: no internet route
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "Postgres: only from the ECS services"
  vpc_id      = module.network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_services" {
  for_each                     = module.svc
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from ${each.key}"
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name}-pg18"
  family = "postgres18"

  parameter {
    name  = "rds.force_ssl"
    value = "1" # reject any unencrypted client connection
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log queries slower than 500 ms (shipped to CloudWatch)
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds cost; Performance Insights + CloudWatch metrics are enough here.
  #checkov:skip=CKV_AWS_293:Deletion protection is off on purpose: the env is destroyed after each session.
  #checkov:skip=CKV_AWS_161:IAM DB auth not used; password from SSM keeps the app driver simple.
  #checkov:skip=CKV2_AWS_30:Query logging is enabled via log_min_duration_statement.
  #checkov:skip=CKV_AWS_354:Performance Insights uses the AWS-managed key.
  #checkov:skip=CKV_AWS_157:Multi-AZ is a variable (default true).
  identifier                      = local.name
  engine                          = "postgres"
  engine_version                  = "18"
  instance_class                  = var.db_instance_class
  allocated_storage               = 20
  max_allocated_storage           = 50 # storage autoscaling cap
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = "ticketrush"
  username                        = "ticketrush"
  password                        = random_password.db.result
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  parameter_group_name            = aws_db_parameter_group.this.name
  multi_az                        = var.db_multi_az
  publicly_accessible             = false
  backup_retention_period         = 7 # point-in-time recovery to any second in 7 days
  backup_window                   = "02:00-03:00"
  maintenance_window              = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot           = true
  deletion_protection             = false
  skip_final_snapshot             = var.db_skip_final_snapshot
  final_snapshot_identifier       = var.db_skip_final_snapshot ? null : "${local.name}-final"
  delete_automated_backups        = true
  auto_minor_version_upgrade      = true
  apply_immediately               = true
  monitoring_interval             = 0
  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}

# ======================================================= ElastiCache (Valkey)
resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.network.data_subnet_ids
}

resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "Valkey: only from the ECS services"
  vpc_id      = module.network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_services" {
  for_each                     = module.svc
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = each.value.security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Valkey from ${each.key}"
}

resource "aws_elasticache_replication_group" "this" {
  #checkov:skip=CKV2_AWS_50:Failover is enabled when cache_replicas > 0 (variable, cost trade-off).
  #checkov:skip=CKV_AWS_191:AWS-managed encryption at rest (no CMK by project decision).
  replication_group_id       = local.name
  description                = "TicketRush cache, rate limits"
  engine                     = "valkey"
  engine_version             = "8.2"
  node_type                  = var.cache_node_type
  num_cache_clusters         = 1 + var.cache_replicas
  automatic_failover_enabled = var.cache_replicas > 0
  multi_az_enabled           = var.cache_replicas > 0
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.cache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true # TLS; clients use rediss://
  auth_token                 = random_password.cache.result
  apply_immediately          = true
  snapshot_retention_limit   = 0 # cache is rebuildable; no backups needed
}

# ======================================================= DynamoDB (issued tickets)
resource "aws_dynamodb_table" "tickets" {
  #checkov:skip=CKV_AWS_119:AWS-owned encryption (no CMK by project decision).
  name         = "${local.name}-tickets"
  billing_mode = "PAY_PER_REQUEST" # pay per request, zero idle cost
  hash_key     = "user_id"
  range_key    = "ticket_id"

  attribute {
    name = "user_id"
    type = "S"
  }
  attribute {
    name = "ticket_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ======================================================= SQS (order events)
resource "aws_sqs_queue" "orders_dlq" {
  name                      = "${local.name}-orders-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate poison messages
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "orders" {
  name                       = "${local.name}-orders"
  visibility_timeout_seconds = 60 # >= 6x the Lambda timeout (AWS guidance)
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "orders_dlq" {
  queue_url = aws_sqs_queue.orders_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.orders.arn]
  })
}
