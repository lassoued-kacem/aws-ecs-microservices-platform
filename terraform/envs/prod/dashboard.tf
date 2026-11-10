# The SRE dashboard, as code. Golden signals first (traffic, errors, latency,
# saturation), then dependencies, async pipeline, edge, and business KPIs.
locals {
  r   = local.region
  alb = aws_lb.this.arn_suffix
  db  = aws_db_instance.this.identifier
  tg  = { for k, s in module.svc : k => s.target_group_arn_suffix }

  w = [
    { type = "text", x = 0, y = 0, width = 24, height = 2, properties = {
      markdown = "# ⚡ TicketRush: production SRE dashboard\nSLO targets (hooks): availability **${var.slo_availability_target}%**, p99 latency **${var.slo_latency_p99_ms} ms**. Runbooks live in `docs/runbooks/`. Traces: X-Ray → Trace Map."
    } },

    # ---- scoreboard
    { type = "metric", x = 0, y = 2, width = 6, height = 4, properties = {
      title = "Availability (non-5xx %)", view = "singleValue", region = local.r, period = 300, stat = "Sum",
      metrics = [
        [{ expression = "100 - 100 * (FILL(m2,0) + FILL(m3,0)) / MAX([m1,1])", label = "Availability %", id = "e1" }],
        ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb, { id = "m1", visible = false }],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb, { id = "m2", visible = false }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb, { id = "m3", visible = false }],
      ]
    } },
    { type = "metric", x = 6, y = 2, width = 6, height = 4, properties = {
      title   = "External canary success %", view = "singleValue", region = local.r, period = 300, stat = "Average",
      metrics = [for c in ["frontend", "events_api", "identity_api", "ticketing_api"] : ["TicketRush/Canary", "Success", "Check", c, { label = c }]]
    } },
    { type = "metric", x = 12, y = 2, width = 6, height = 4, properties = {
      title = "Tickets sold / revenue (1h)", view = "singleValue", region = local.r, period = 3600, stat = "Sum",
      metrics = [
        ["TicketRush/Business", "TicketsSold", "Service", "ticketing", { label = "Tickets" }],
        ["TicketRush/Business", "Revenue", "Service", "ticketing", { label = "Revenue €" }],
        ["TicketRush/Business", "SoldOutRejections", "Service", "ticketing", { label = "Sold-out rejections" }],
      ]
    } },
    { type = "alarm", x = 18, y = 2, width = 6, height = 4, properties = {
      title  = "Alarm status",
      alarms = concat([aws_cloudwatch_composite_alarm.user_impact.arn, aws_cloudwatch_metric_alarm.alb_5xx_rate.arn], [for a in aws_cloudwatch_metric_alarm.simple : a.arn])
    } },

    # ---- traffic & errors
    { type = "metric", x = 0, y = 6, width = 8, height = 6, properties = {
      title   = "Traffic: requests/min by service", view = "timeSeries", stacked = true, region = local.r, period = 60, stat = "Sum",
      metrics = [for k, t in local.tg : ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", t, { label = k, stat = "Sum" }]]
    } },
    { type = "metric", x = 8, y = 6, width = 8, height = 6, properties = {
      title = "Errors: HTTP status classes", view = "timeSeries", region = local.r, period = 60, stat = "Sum",
      metrics = [
        ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", local.alb, { label = "2xx", color = "#2ca02c" }],
        ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.alb, { label = "4xx", color = "#ff7f0e" }],
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb, { label = "5xx target", color = "#d62728" }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb, { label = "5xx ALB", color = "#9467bd" }],
      ]
    } },
    { type = "metric", x = 16, y = 6, width = 8, height = 6, properties = {
      title       = "Latency: p50 / p90 / p95 / p99 (seconds)", view = "timeSeries", region = local.r, period = 60,
      metrics     = [for p in ["p50", "p90", "p95", "p99"] : ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb, { stat = p, label = p }]]
      annotations = { horizontal = [{ label = "p99 SLO", value = var.slo_latency_p99_ms / 1000 }] }
    } },

    # ---- saturation
    { type = "metric", x = 0, y = 12, width = 8, height = 6, properties = {
      title   = "ECS CPU % by service", view = "timeSeries", region = local.r, period = 60, stat = "Average",
      metrics = [for k, _ in module.svc : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", k, { label = k }]]
    } },
    { type = "metric", x = 8, y = 12, width = 8, height = 6, properties = {
      title   = "ECS memory % by service", view = "timeSeries", region = local.r, period = 60, stat = "Average",
      metrics = [for k, _ in module.svc : ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", k, { label = k }]]
    } },
    { type = "metric", x = 16, y = 12, width = 8, height = 6, properties = {
      title   = "Healthy tasks behind the ALB", view = "timeSeries", region = local.r, period = 60, stat = "Minimum",
      metrics = [for k, t in local.tg : ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", t, "LoadBalancer", local.alb, { label = k }]]
    } },

    # ---- data tier
    { type = "metric", x = 0, y = 18, width = 8, height = 6, properties = {
      title = "RDS: CPU % and connections", view = "timeSeries", region = local.r, period = 60, stat = "Average",
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db, { label = "CPU %" }],
        ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.db, { label = "connections", yAxis = "right" }],
      ]
    } },
    { type = "metric", x = 8, y = 18, width = 8, height = 6, properties = {
      title = "RDS: read / write latency (s)", view = "timeSeries", region = local.r, period = 60, stat = "Average",
      metrics = [
        ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", local.db, { label = "read" }],
        ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", local.db, { label = "write" }],
      ]
    } },
    { type = "metric", x = 16, y = 18, width = 8, height = 6, properties = {
      title = "Valkey: cache hit ratio (app-side) & memory", view = "timeSeries", region = local.r, period = 60, stat = "Sum",
      metrics = [
        [{ expression = "100 * h / MAX([h + m, 1])", label = "events cache hit %", id = "hr" }],
        ["TicketRush/Business", "CacheHit", "Service", "ticketing", "Resource", "events", { id = "h", visible = false }],
        ["TicketRush/Business", "CacheMiss", "Service", "ticketing", "Resource", "events", { id = "m", visible = false }],
        ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", local.cache_node, { label = "memory %", stat = "Maximum", yAxis = "right" }],
      ]
    } },

    # ---- async pipeline
    { type = "metric", x = 0, y = 24, width = 8, height = 6, properties = {
      title = "Orders queue: depth, age, DLQ", view = "timeSeries", region = local.r, period = 60, stat = "Maximum",
      metrics = [
        ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.orders.name, { label = "queue depth" }],
        ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.orders_dlq.name, { label = "DLQ depth", color = "#d62728" }],
        ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.orders.name, { label = "oldest msg age (s)", yAxis = "right" }],
      ]
    } },
    { type = "metric", x = 8, y = 24, width = 8, height = 6, properties = {
      title = "Lambdas: invocations / errors / throttles", view = "timeSeries", region = local.r, period = 60, stat = "Sum",
      metrics = flatten([for f in [module.ticket_issuer.function_name, module.canary.function_name] : [
        ["AWS/Lambda", "Invocations", "FunctionName", f, { label = "${f} inv" }],
        ["AWS/Lambda", "Errors", "FunctionName", f, { label = "${f} err" }],
        ["AWS/Lambda", "Throttles", "FunctionName", f, { label = "${f} thr" }],
      ]])
    } },
    { type = "metric", x = 16, y = 24, width = 8, height = 6, properties = {
      title   = "Canary latency from outside (ms)", view = "timeSeries", region = local.r, period = 60, stat = "Average",
      metrics = [for c in ["frontend", "events_api", "identity_api", "ticketing_api"] : ["TicketRush/Canary", "LatencyMs", "Check", c, { label = c }]]
    } },

    # ---- edge & network
    { type = "metric", x = 0, y = 30, width = 8, height = 6, properties = {
      title = "WAF: allowed vs blocked", view = "timeSeries", region = local.r, period = 60, stat = "Sum",
      metrics = [
        ["AWS/WAFV2", "AllowedRequests", "WebACL", aws_wafv2_web_acl.this.name, "Region", local.r, "Rule", "ALL", { label = "allowed" }],
        ["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.this.name, "Region", local.r, "Rule", "ALL", { label = "blocked", color = "#d62728" }],
      ]
    } },
    { type = "metric", x = 8, y = 30, width = 8, height = 6, properties = {
      # CloudFront metrics only exist in us-east-1; a widget can query another region.
      title = "CloudFront: requests and error rates", view = "timeSeries", region = "us-east-1", period = 60,
      metrics = [
        ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.this.id, "Region", "Global", { stat = "Sum", label = "requests" }],
        ["AWS/CloudFront", "4xxErrorRate", "DistributionId", aws_cloudfront_distribution.this.id, "Region", "Global", { stat = "Average", label = "4xx %", yAxis = "right" }],
        ["AWS/CloudFront", "5xxErrorRate", "DistributionId", aws_cloudfront_distribution.this.id, "Region", "Global", { stat = "Average", label = "5xx %", yAxis = "right" }],
      ]
    } },
    { type = "metric", x = 16, y = 30, width = 8, height = 6, properties = {
      title = "NAT gateway: bytes out & port errors", view = "timeSeries", region = local.r, period = 60, stat = "Sum",
      metrics = [
        ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", module.network.nat_gateway_ids[0], { label = "bytes out" }],
        ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", module.network.nat_gateway_ids[0], { label = "port alloc errors", yAxis = "right" }],
      ]
    } },

    # ---- logs
    { type = "log", x = 0, y = 36, width = 12, height = 6, properties = {
      title = "Slowest requests (last 3h)", region = local.r, view = "table",
      query = "SOURCE '${module.svc["identity"].log_group_name}' | SOURCE '${module.svc["ticketing"].log_group_name}' | fields @timestamp, method, path, status, duration_ms | filter msg = \"request\" | sort duration_ms desc | limit 20"
    } },
    { type = "log", x = 12, y = 36, width = 12, height = 6, properties = {
      title = "Errors by message", region = local.r, view = "table",
      query = "SOURCE '${module.svc["identity"].log_group_name}' | SOURCE '${module.svc["ticketing"].log_group_name}' | filter level = \"ERROR\" or level = \"WARNING\" | stats count() as n by level, msg | sort n desc | limit 20"
    } },
  ]
}

resource "aws_cloudwatch_dashboard" "sre" {
  dashboard_name = "${local.name}-sre"
  dashboard_body = jsonencode({ widgets = local.w })
}
