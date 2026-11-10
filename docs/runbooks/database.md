# Database (RDS PostgreSQL Multi-AZ)

- **CPU high:** Performance Insights → Top SQL. Missing index? Lock contention on `events` during a drop is expected (row lock per event).
- **Connections high:** each task pools 5 + 5 overflow. 4 tasks × 2 services × 10 = 80 max, and db.t4g.micro allows about 80-110. If you scale tasks further, lower the pool size or move up a class.
- **Storage low:** storage autoscaling goes up to 50 GB. Check for runaway tables.
- **Forced failover test:** `aws rds reboot-db-instance --db-instance-identifier ticketrush-prod --force-failover` (about 1-2 min).
- **Point-in-time restore** (creates a NEW instance; point the app at it via `DB_HOST`):
  `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier ticketrush-prod --target-db-instance-identifier ticketrush-prod-restore --restore-time 2026-11-10T15:00:00Z`
