# Cache (ElastiCache Valkey)

The app **fails open**: if Valkey is down, everything still works, just slower (DB load goes up). So a cache incident usually shows up as latency or DB CPU, not errors.

- **Memory > 85%:** keys all have TTLs (5-300 s), so growth means a bug (a key without a TTL) or a bigger node is needed. `cache_node_type`.
- **Connection issues:** logs show `cache get failed`. Check the SG (6379 from the service SGs) and that `REDIS_URL` uses `rediss://` (TLS is mandatory).
- **Failover:** only with `cache_replicas >= 1`. A single node is replaced in place (minutes, fail-open meanwhile).
