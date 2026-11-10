# Runbooks

Start here when an alarm fires. Every alarm description names its runbook.

| Alarm | Runbook |
|---|---|
| `ticketrush-prod-USER-IMPACT` (composite) | Triage below, then the specific runbook |
| `alb-5xx-rate` | [high-5xx.md](high-5xx.md) |
| `alb-p99-latency` | [high-latency.md](high-latency.md) |
| `<svc>-unhealthy-targets`, `<svc>-no-healthy-targets` | [failed-deployment.md](failed-deployment.md) |
| `rds-cpu`, `rds-free-storage` | [database.md](database.md) |
| `cache-memory` | [cache.md](cache.md) |
| `orders-dlq-not-empty`, `orders-oldest-message`, `issuer-errors` | [async-backlog.md](async-backlog.md) |
| `canary-failing` | [canary-failing.md](canary-failing.md) |
| `nat-port-allocation` | [nat.md](nat.md) |
| WAF blocking real users | [waf-false-positive.md](waf-false-positive.md) |

## 5-minute triage (any alarm)

1. **Is it user-visible?** Dashboard `ticketrush-prod-sre`, top row: availability %, canary success.
2. **What changed?** `aws ecs describe-services --cluster ticketrush-prod --services identity ticketing --query 'services[].deployments'`, plus the latest GitHub Actions runs. Most incidents follow a change.
3. **Which layer?** ALB 5xx (no healthy targets) vs target 5xx (app errors) vs latency only. Then data tier, then async.
4. **Mitigate first, debug later:** roll back (re-run App CD for the previous green commit, or `aws ecs update-service --task-definition <previous revision>`), scale out, or fail over.
5. Write the post-incident note (template below).

## Post-incident template

```
Title / date / duration (detection -> mitigation -> resolution)
Impact: who, how many requests failed, SLO budget burned
Timeline (UTC)
Root cause (5 whys)
What went well / what went badly
Action items (owner, due date)
```
