# WAF false positive

1. Find blocked requests: log group `aws-waf-logs-ticketrush-prod` (only BLOCKs are logged). The `terminatingRuleId` field names the rule.
2. Logs Insights: `fields @timestamp, httpRequest.uri, terminatingRuleId, httpRequest.clientIp | sort @timestamp desc | limit 50`
3. Fix: add a `rule_action_override { name = "<rule>" action_to_use { count {} } }` inside that managed rule group's statement in `terraform/envs/prod/alb.tf`, open a PR, and merge.
4. Rate limit hitting real users? Raise `waf_rate_limit_per_5min`.
