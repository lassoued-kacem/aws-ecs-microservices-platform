# Failed deployment / tasks crash-looping / no healthy targets

1. `aws ecs describe-services --cluster ticketrush-prod --services <svc> --query 'services[0].{events:events[:8],deployments:deployments}'`
   - Events say "circuit breaker triggered, rolling back": the bad revision is already being replaced. Check the GitHub run.
2. Why did tasks die? `aws ecs list-tasks --cluster ticketrush-prod --desired-status STOPPED --service-name <svc>`, then `aws ecs describe-tasks ... --query 'tasks[].{reason:stoppedReason,containers:containers[].reason}'`
   - `CannotPullContainerError`: image tag missing or NAT down.
   - `ResourceInitializationError ... ssm`: the execution role cannot read a parameter (did a secret name change?).
   - Exit code 1 at start: see logs `/ecs/ticketrush-prod-<svc>`. Usually DB TLS, password or migration errors.
   - Health check failing: `/health` must answer within 5 s. Grace period is 60 s.
3. Manual rollback: `aws ecs update-service --cluster ticketrush-prod --service <svc> --task-definition ticketrush-prod-<svc>:<last good revision>`.
4. Shell into a running task: `aws ecs execute-command --cluster ticketrush-prod --task <id> --container app --interactive --command /bin/sh`.
