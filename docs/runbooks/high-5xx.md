# High 5xx rate

**Alarm:** `alb-5xx-rate` (> 2% of requests).

1. Dashboard "Errors: HTTP status classes". **ALB 5xx** (502/503/504) means no healthy target or a timeout, so go to [failed-deployment.md](failed-deployment.md). **Target 5xx** means the app returns 500s, continue below.
2. Find the error: Logs Insights → saved query `ticketrush-prod/top-errors`.
3. Common causes:
   - DB unreachable or failing over → [database.md](database.md). `pool_pre_ping` recovers within about 1-2 min of the failover finishing.
   - A bad deploy that passed `/health` but fails real requests → roll back: `aws ecs update-service --cluster ticketrush-prod --service <svc> --task-definition ticketrush-prod-<svc>:<previous revision>`.
4. X-Ray Trace Map: filter `http.status_code >= 500` to see which dependency span fails.
