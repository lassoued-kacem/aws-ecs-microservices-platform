# Measured numbers (fill in from REAL runs only)

| Metric | How to measure | Value |
|---|---|---|
| Merge → running in production | GitHub Actions "App CD" total duration | _ |
| Image build time (cached / cold) | build-push step duration | _ |
| Full environment create | `time make apply` | _ |
| Full environment destroy | `time make destroy` | _ |
| Task killed → replacement healthy | `aws ecs stop-task`, watch HealthyHostCount | _ |
| RDS forced failover → app healthy again | reboot with failover, watch canary | _ |
| p50 / p95 / p99 latency under `make load` | dashboard latency widget | _ |
| Flash drop: buyers / seats / oversells | `make load` output | 60 / 10 / **0** |
| Availability during deploy (canary) | canary success % during a deploy | _ |
| Cost per hour of the running stack | Cost Explorer (next day) or Infracost | _ |
| Checkov checks passed / failed / skipped | `make lint` | 487 / 0 / 89 |
| Tests | pytest + terraform test | 18 Python, 9 Terraform |

Screenshots to add to README: dashboard, X-Ray trace map, a PR with plan + Infracost comments, a rolled-back deploy.
