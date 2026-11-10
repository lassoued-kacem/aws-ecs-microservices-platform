# High latency (p99 above SLO)

1. Dashboard latency widget: is p50 high too (everything slow) or only p99 (some requests)?
2. Logs Insights `ticketrush-prod/latency-by-route`: which route?
3. Saturation row: CPU near 100% → autoscaling should add tasks (max 4). If at max, raise `service_max_count`. argon2 login is CPU-heavy by design.
4. RDS read/write latency up → [database.md](database.md) (Performance Insights → top SQL).
5. Cache hit ratio dropped → [cache.md](cache.md). Every miss is a DB query.
6. X-Ray: open a slow trace and look for the longest span.
