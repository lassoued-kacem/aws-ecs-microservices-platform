# ---------------------------------------------------------------- alert channel
resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:CloudWatch alarms cannot publish to a topic encrypted with the AWS-managed SNS key, and CMKs are out of scope.
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # you must click the confirmation link in the email
}

locals {
  alb_dim       = { LoadBalancer = aws_lb.this.arn_suffix }
  cache_node    = tolist(aws_elasticache_replication_group.this.member_clusters)[0]
  alarm_actions = [aws_sns_topic.alerts.arn]

  # name => alarm definition. One place to read every threshold.
  alarms = {
    alb-5xx-rate = {
      description = "More than 2% of requests return 5xx (availability SLI burning). Runbook: docs/runbooks/high-5xx.md"
      metric_math = true
    }
    alb-p99-latency = {
      namespace   = "AWS/ApplicationELB", metric = "TargetResponseTime", stat = "p99", dims = local.alb_dim
      threshold   = var.slo_latency_p99_ms / 1000, comparison = "GreaterThanThreshold", periods = 3
      description = "p99 latency above SLO target. Runbook: docs/runbooks/high-latency.md"
    }
    rds-cpu = {
      namespace   = "AWS/RDS", metric = "CPUUtilization", stat = "Average", dims = { DBInstanceIdentifier = aws_db_instance.this.identifier }
      threshold   = 80, comparison = "GreaterThanThreshold", periods = 3
      description = "RDS CPU > 80%. Runbook: docs/runbooks/database.md"
    }
    rds-free-storage = {
      namespace   = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", dims = { DBInstanceIdentifier = aws_db_instance.this.identifier }
      threshold   = 2 * 1024 * 1024 * 1024, comparison = "LessThanThreshold", periods = 1
      description = "Less than 2 GiB free on RDS. Runbook: docs/runbooks/database.md"
    }
    cache-memory = {
      namespace   = "AWS/ElastiCache", metric = "DatabaseMemoryUsagePercentage", stat = "Maximum", dims = { CacheClusterId = local.cache_node }
      threshold   = 85, comparison = "GreaterThanThreshold", periods = 3
      description = "Valkey memory > 85% (evictions imminent). Runbook: docs/runbooks/cache.md"
    }
    orders-dlq-not-empty = {
      namespace   = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum", dims = { QueueName = aws_sqs_queue.orders_dlq.name }
      threshold   = 0, comparison = "GreaterThanThreshold", periods = 1
      description = "Orders failed ticket issuance 5 times and are parked in the DLQ. Runbook: docs/runbooks/async-backlog.md"
    }
    orders-oldest-message = {
      namespace   = "AWS/SQS", metric = "ApproximateAgeOfOldestMessage", stat = "Maximum", dims = { QueueName = aws_sqs_queue.orders.name }
      threshold   = 120, comparison = "GreaterThanThreshold", periods = 2
      description = "Tickets are not being issued (oldest order event > 2 min). Runbook: docs/runbooks/async-backlog.md"
    }
    issuer-errors = {
      namespace   = "AWS/Lambda", metric = "Errors", stat = "Sum", dims = { FunctionName = module.ticket_issuer.function_name }
      threshold   = 0, comparison = "GreaterThanThreshold", periods = 1
      description = "Ticket issuer Lambda is failing. Runbook: docs/runbooks/async-backlog.md"
    }
    canary-failing = {
      namespace   = "TicketRush/Canary", metric = "Success", stat = "Average", dims = { Check = "events_api" }
      threshold   = 1, comparison = "LessThanThreshold", periods = 3, missing = "breaching"
      description = "External canary cannot load /api/events through CloudFront for 3 minutes. Runbook: docs/runbooks/canary-failing.md"
    }
    nat-port-allocation = {
      namespace   = "AWS/NATGateway", metric = "ErrorPortAllocation", stat = "Sum", dims = { NatGatewayId = module.network.nat_gateway_ids[0] }
      threshold   = 0, comparison = "GreaterThanThreshold", periods = 1
      description = "NAT gateway is out of source ports. Runbook: docs/runbooks/nat.md"
    }
  }
  simple_alarms = { for k, v in local.alarms : k => v if !lookup(v, "metric_math", false) }
}

resource "aws_cloudwatch_metric_alarm" "simple" {
  for_each            = local.simple_alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dims
  statistic           = contains(["Average", "Sum", "Minimum", "Maximum", "SampleCount"], each.value.stat) ? each.value.stat : null
  extended_statistic  = contains(["Average", "Sum", "Minimum", "Maximum", "SampleCount"], each.value.stat) ? null : each.value.stat
  period              = 60
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison
  treat_missing_data  = lookup(each.value, "missing", "notBreaching")
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Error RATE, not count: 5 errors out of 10 requests is an incident, 5 out of 100k is not.
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name}-alb-5xx-rate"
  alarm_description   = local.alarms["alb-5xx-rate"].description
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "rate"
    expression  = "100 * (FILL(e5xx,0) + FILL(t5xx,0)) / IF(FILL(req,0) > 0, FILL(req,0), 1)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "t5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "e5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
}

# Per-service "fewer tasks than desired" and "no healthy targets".
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each            = module.svc
  alarm_name          = "${local.name}-${each.key}-unhealthy-targets"
  alarm_description   = "${each.key}: ALB sees unhealthy tasks. Runbook: docs/runbooks/failed-deployment.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = each.value.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  for_each            = module.svc
  alarm_name          = "${local.name}-${each.key}-no-healthy-targets"
  alarm_description   = "${each.key} has ZERO healthy tasks: service down. Runbook: docs/runbooks/failed-deployment.md"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = each.value.target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Composite: page-worthy "users are hurting" signal = canary failing AND
# (5xx rate high OR a service has no healthy targets). Fewer, better alerts.
resource "aws_cloudwatch_composite_alarm" "user_impact" {
  alarm_name        = "${local.name}-USER-IMPACT"
  alarm_description = "Customers are affected: external canary failing together with server-side errors. Start at docs/runbooks/README.md"
  alarm_actions     = local.alarm_actions
  ok_actions        = local.alarm_actions
  alarm_rule = format(
    "ALARM(\"%s\") AND (ALARM(\"%s\") OR %s)",
    aws_cloudwatch_metric_alarm.simple["canary-failing"].alarm_name,
    aws_cloudwatch_metric_alarm.alb_5xx_rate.alarm_name,
    join(" OR ", [for a in aws_cloudwatch_metric_alarm.no_healthy_targets : "ALARM(\"${a.alarm_name}\")"])
  )
}

# ---------------------------------------------------------------- saved Logs Insights queries
resource "aws_cloudwatch_query_definition" "errors" {
  name            = "${local.name}/top-errors"
  log_group_names = [for s in module.svc : s.log_group_name]
  query_string = join("\n", [
    "fields @timestamp, logger, msg, exc",
    "| filter level = \"ERROR\"",
    "| stats count() as errors by logger, msg",
    "| sort errors desc",
    "| limit 20",
  ])
}

resource "aws_cloudwatch_query_definition" "slow" {
  name            = "${local.name}/slowest-requests"
  log_group_names = [for s in module.svc : s.log_group_name]
  query_string = join("\n", [
    "fields @timestamp, method, path, status, duration_ms",
    "| filter msg = \"request\"",
    "| sort duration_ms desc",
    "| limit 50",
  ])
}

resource "aws_cloudwatch_query_definition" "latency_by_route" {
  name            = "${local.name}/latency-by-route"
  log_group_names = [for s in module.svc : s.log_group_name]
  query_string = join("\n", [
    "filter msg = \"request\"",
    "| stats count() as requests, pct(duration_ms, 50) as p50, pct(duration_ms, 95) as p95, pct(duration_ms, 99) as p99 by method, path",
    "| sort requests desc",
  ])
}
