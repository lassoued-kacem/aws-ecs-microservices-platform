# The ALB is internet-facing (CloudFront needs a public origin) but locked twice:
#  1. its SG only admits CloudFront's origin-facing IP ranges (managed prefix list)
#  2. listener rules only forward requests carrying the secret X-Origin-Verify
#     header that only our distribution adds. Everything else -> 403.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  # Dedicated SG: the CloudFront prefix list counts as ~55 rules against the SG quota.
  name        = "${local.name}-alb"
  description = "ALB: HTTP from CloudFront origin-facing ranges only"
  vpc_id      = module.network.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  #checkov:skip=CKV_AWS_260:Source is the CloudFront origin-facing prefix list, not 0.0.0.0/0 (false positive).
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "CloudFront origin-facing"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_services" {
  for_each                     = module.svc
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = each.value.security_group_id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  description                  = "To ${each.key} tasks"
}

resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_76:AWSManagedRulesKnownBadInputsRuleSet (attached) contains the Log4j rules.
  #checkov:skip=CKV_AWS_150:Deletion protection off: environment is destroyed after each session.
  #checkov:skip=CKV_AWS_91:Access logs skipped for cost/simplicity; CloudFront + WAF logs + app logs cover requests.
  #checkov:skip=CKV2_AWS_20:No certificate without a domain; HTTPS terminates at CloudFront (documented trade-off).
  #checkov:skip=CKV2_AWS_28:WAF IS attached via aws_wafv2_web_acl_association (check does not follow it).
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.network.public_subnet_ids
  drop_invalid_header_fields = true # mitigates HTTP request smuggling
  idle_timeout               = 30
  enable_deletion_protection = false
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:HTTP only on the CloudFront->ALB hop (no domain = no cert); viewer side is HTTPS.
  #checkov:skip=CKV_AWS_103:See CKV_AWS_2.
  #checkov:skip=CKV2_AWS_74:See CKV_AWS_2.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"detail\":\"forbidden\"}"
      status_code  = "403"
    }
  }
}

# ---------------------------------------------------------------- WAF (regional, on ALB)
resource "aws_wafv2_web_acl" "this" {
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Per-client rate limit. Behind CloudFront the TCP source is a CloudFront IP,
  # so we key on the real client IP from X-Forwarded-For.
  rule {
    name     = "rate-limit-per-client"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "FORWARDED_IP"
        forwarded_ip_config {
          header_name       = "X-Forwarded-For"
          fallback_behavior = "MATCH"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet" # includes Log4Shell patterns
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-sqli"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_158:AWS-managed encryption (no CMK by project decision).
  #checkov:skip=CKV_AWS_338:Short retention is intentional to control cost.
  name              = "aws-waf-logs-${local.name}" # WAF requires the aws-waf-logs- prefix
  retention_in_days = 7
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn
  # Never log the session cookie.
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  # Only log blocked requests: enough for false-positive triage, far cheaper.
  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }
}
