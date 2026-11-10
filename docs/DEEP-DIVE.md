# DEEP-DIVE: every decision, in boring detail

This file explains **why** each piece exists, which value was chosen and why, what the alternatives were, and what breaks if you change it. Read it top to bottom once, then use it as a reference when an interviewer asks "why did you…?".

Contents:

1. [The product and the hard problem](#1-the-product-and-the-hard-problem)
2. [Service boundaries](#2-service-boundaries)
3. [Identity service: auth done properly](#3-identity-service-auth-done-properly)
4. [Ticketing service: correctness under concurrency](#4-ticketing-service-correctness-under-concurrency)
5. [Caching with ElastiCache (Valkey)](#5-caching-with-elasticache-valkey)
6. [Async pipeline: SQS → Lambda → DynamoDB](#6-async-pipeline-sqs--lambda--dynamodb)
7. [Database and migrations](#7-database-and-migrations)
8. [Containers](#8-containers)
9. [Frontend and the edge](#9-frontend-and-the-edge)
10. [Network](#10-network)
11. [ECS / Fargate](#11-ecs--fargate)
12. [Secrets](#12-secrets)
13. [IAM and the CI roles](#13-iam-and-the-ci-roles)
14. [Terraform structure](#14-terraform-structure)
15. [CI/CD](#15-cicd)
16. [Observability](#16-observability)
17. [Security scanning and skipped checks](#17-security-scanning-and-skipped-checks)
18. [Cost](#18-cost)
19. [Known limitations and next steps](#19-known-limitations-and-next-steps)
20. [Interview cheat-sheet](#20-interview-cheat-sheet)

---

## 1. The product and the hard problem

**TicketRush** sells concert/event tickets in "drops". The interesting engineering is not the CRUD. It is what happens when **demand far exceeds supply in a very short window**:

- Many requests try to modify **the same row** (the event's remaining inventory) at the same moment.
- Clients **retry** (double-click, mobile network flaps, gateway timeouts), and a retry must not buy twice.
- Read traffic (event pages, remaining stock) is 100x write traffic.
- Ticket issuance (generating codes, writing them somewhere) should not add latency to checkout.

Why this subject: you can explain it in 30 seconds ("how do you guarantee you never sell seat #11 of 10?"), it has a demo with a visible outcome (the flash-drop event sells out at exactly 10), and it naturally needs every AWS service in the brief (relational DB, cache, queue, functions, NoSQL, CDN, WAF) without forcing any of them.

## 2. Service boundaries

| Unit | Runs on | Owns | Why separate |
|---|---|---|---|
| `identity` | ECS Fargate | `identity.users` (Postgres schema) | Different security posture (password hashes), different scaling (argon2 is CPU-heavy), different change rate. A classic bounded context |
| `ticketing` | ECS Fargate | `ticketing.events`, `ticketing.orders` | The transactional core |
| `ticket_issuer` | Lambda | DynamoDB `tickets` items | Event-driven, bursty, idle most of the time: the textbook Lambda workload |
| `canary` | Lambda | nothing (emits metrics) | Must run **outside** the VPC and outside ECS, to see what users see |
| `frontend` | S3 + CloudFront | static assets | Static files do not need servers |

**Why only 2 containers:** the user asked for the minimum number of services that really work. Two services already prove service-to-service trust (JWT), independent deploys (path-filtered pipeline), and per-service IAM. A third service would add explanation cost without a new concept.

**Why no Service Connect / service mesh:** the services never call each other. Identity issues a signed token, and ticketing verifies it locally. No network hop means one fewer failure mode, so Service Connect would be dead weight. If they ever need to talk (for example ticketing asking identity for a profile), add `service_connect_configuration` in the ecs-service module.

**How requests reach each service:** the ALB routes by path. `/api/auth/*` → identity (rule priority 10), `/api/*` → ticketing (priority 20). Priority matters: ALB evaluates rules lowest-first, and `/api/auth/login` also matches `/api/*`, so the more specific rule must have the lower number.

## 3. Identity service: auth done properly

File: `services/identity/app/`.

### 3.1 Password hashing: argon2id

- `argon2-cffi`'s `PasswordHasher()` defaults to **argon2id** with RFC 9106 low-memory parameters. OWASP's first recommendation.
- Why not bcrypt: bcrypt truncates input at 72 bytes and is not memory-hard. Why not PBKDF2: GPU-friendly, so fast cracking.
- `needs_rehash()` on every successful login: if the parameters are raised later, users are silently upgraded the next time they log in.
- Passwords are capped at **128 characters**. Hashing has a CPU and memory cost, and an unbounded input is a cheap DoS vector.
- The minimum is **12 characters** and there are no composition rules (NIST SP 800-63B: length beats "one symbol and one digit").

### 3.2 No user enumeration

`login()` returns the **same status (401) and the same message** for "no such email" and "wrong password". It also does the **same work**: when the user does not exist, it still verifies against a dummy argon2 hash (`_DUMMY_HASH`), so response timing does not reveal whether an email is registered. Registration does reveal it (409), which is an accepted, industry-normal trade-off for UX. Mitigate with rate limiting.

### 3.3 Brute-force throttling

Fixed window in Valkey: key `identity:login:<email>`, `INCR` + `EXPIRE 300`, more than 5 attempts gives 429. A successful login resets the counter. It **fails open**: if Valkey is down, logins still work. Locking every user out because a cache is down would turn a cache incident into a full outage. The WAF rate limit is the second layer.

### 3.4 Tokens: JWT in an HttpOnly cookie

| Claim / setting | Value | Why |
|---|---|---|
| alg | HS256, verified with `algorithms=["HS256"]` | The explicit allow-list blocks the `alg: none` and alg-confusion attacks |
| `exp` | 1 hour | Short-lived. No refresh-token machinery (scope trade-off). The user logs in again after an hour |
| `iss`, `aud` | `ticketrush-identity`, `ticketrush` | Tokens minted for another system cannot be replayed here |
| `require` | exp, iat, sub, iss, aud | A token missing a claim is rejected rather than treated as valid |
| `jti` | random | Enables a future deny-list |

**Cookie:** `HttpOnly` (JavaScript, and therefore XSS, cannot steal it), `Secure` (HTTPS only; disabled locally through `COOKIE_SECURE=false`), `SameSite=Strict` (the browser never attaches it to cross-site requests, which is the CSRF defense), `Path=/api` (never sent with static asset requests).

**Why a cookie and not `localStorage` + `Authorization` header:** `localStorage` is readable by any injected script. Because the SPA and API share **one origin** through CloudFront, cookies work without CORS. The services still accept `Authorization: Bearer` for API clients and tests.

**Why HS256 and not RS256:** with HS256 both services hold the same key, so ticketing *could* mint tokens. Inside one team and one trust boundary that is acceptable, and it keeps one secret instead of a key pair plus a JWKS endpoint. The upgrade path is in section 19.

### 3.5 Health endpoints (two on purpose)

- `/health`: **liveness**. Used by the ALB target group and the ECS container health check. Touches no dependency. If it checked the DB, a 30-second RDS failover would make ECS kill every healthy task and turn a blip into an outage.
- `/api/auth/health`: **readiness / deep check**. Runs `SELECT 1`. Reached through CloudFront and used by the canary and the smoke test.

## 4. Ticketing service: correctness under concurrency

File: `services/ticketing/app/main.py`, function `create_order`.

### 4.1 The anti-oversell statement

```sql
UPDATE ticketing.events
   SET available = available - :qty
 WHERE id = :id AND available >= :qty
RETURNING price_cents, name;
```

How it works: Postgres takes a **row lock** on the event row for the UPDATE. Concurrent UPDATEs on the same row queue behind it. When the first commits, the next one **re-evaluates the WHERE clause against the new row version** (READ COMMITTED semantics). Once `available` reaches 0, `available >= 1` is false, zero rows are returned, and the API answers 409 "not enough tickets left".

Alternatives rejected:

| Approach | Problem |
|---|---|
| `SELECT available` then `UPDATE` in app code | Classic race: two requests both read 1 and both sell |
| `SELECT … FOR UPDATE` then update | Correct, but holds the lock across a round trip, so it is slower. The conditional UPDATE does both in one statement |
| `SERIALIZABLE` isolation | Correct but throws serialization failures under contention, so you need retry loops |
| Decrement in Redis (`DECR`) | Fast, but now there are two sources of truth, and a crash between Redis and Postgres loses or duplicates seats |

Belt and braces: the table has `CHECK (available >= 0 AND available <= capacity)`. Even a future buggy code path cannot persist an oversell.

**Proof:** `tests/test_ticketing.py::test_no_oversell_under_concurrency` fires 40 concurrent purchases at a 10-seat event and asserts exactly 10 × 201, 30 × 409, `available = 0` and 10 order rows. It runs in CI against a real Postgres.

### 4.2 Idempotency

The client sends `Idempotency-Key: <uuid>` (the React app generates one per purchase intent and keeps it across retries). The server:

1. Looks up `(user_id, idempotency_key)` and returns the existing order if found.
2. Otherwise processes the purchase and inserts with `UNIQUE(user_id, idempotency_key)`.
3. If two identical requests race past step 1, the second one's INSERT violates the unique constraint. We catch `IntegrityError`, roll back (which also undoes its inventory decrement, since it is the same transaction), and return the winner's order.

The key is scoped **per user**, so one user cannot collide with another user's key.

### 4.3 Per-user cap (max 6 per person per event)

Summing a user's existing quantities and comparing is a race (two parallel requests both see 4 and both add 2). We serialise **only that user × that event** with `pg_advisory_xact_lock(hashtextextended('<user>:<event>', 0))`. Other buyers are not blocked, and the lock is released automatically at commit or rollback, so it cannot leak.

### 4.4 Other details

- Per-user purchase rate limit: 10/minute in Valkey (fails open).
- UUID path params are parsed and a bad value gives 404, not 500.
- Business metrics through **CloudWatch Embedded Metric Format**: `aws.emit_metric()` prints one JSON line with an `_aws` block. CloudWatch Logs turns it into a metric (`TicketRush/Business`), with no `PutMetricData` call, no extra latency and no extra IAM permission. Metrics: `TicketsSold`, `Revenue`, `SoldOutRejections`, `CacheHit`, `CacheMiss`.

## 5. Caching with ElastiCache (Valkey)

- **Pattern:** cache-aside. Read the cache; on a miss, read Postgres and write the cache with a TTL. On purchase, delete the affected keys (`events:v1`, `event:v1:<id>`).
- **TTLs:** list 15 s, single event 5 s. Short on purpose: stale stock numbers are harmless (the UPDATE is the truth) but should not be stale for long. The `v1` in keys allows a format change without a flush.
- **What is NOT cached:** anything that decides money or seats. The cache only absorbs reads.
- **Fail-open:** all cache calls catch `RedisError` and use 0.5 s socket timeouts, so a dead cache adds at most about 0.5 s and the service keeps working on Postgres.
- **Why Valkey and not Redis OSS:** Valkey is the Linux Foundation fork of Redis, wire-compatible (the `redis` Python client works unchanged), and ElastiCache prices it about 20% below Redis OSS. Version 8.2 (available in eu-west-3, verified).
- **Security:** `transit_encryption_enabled` (TLS; the client uses `rediss://`) + `auth_token` (48 random chars from SSM) + at-rest encryption + isolated subnets + SG allowing only the two services.
- **Topology:** `cache_replicas = 0` by default (one node). Set it to 1 for a replica in another AZ with automatic failover. It doubles the cost, so it is a variable.

## 6. Async pipeline: SQS → Lambda → DynamoDB

**Why async:** ticket issuance (generating codes, writing documents, later sending emails and PDFs) is not needed to confirm a purchase. Putting it on a queue keeps checkout latency flat and lets issuance retry independently.

| Setting | Value | Why |
|---|---|---|
| Queue visibility timeout | 60 s | AWS guidance: at least 6x the function timeout (10 s), so a slow invocation is not redelivered while still running |
| `maxReceiveCount` | 5 | After 5 failed attempts the message goes to the **DLQ**, so poison messages do not loop forever |
| DLQ retention | 14 days (max) | Time to investigate and redrive |
| Redrive allow policy | only from the orders queue | Hygiene |
| `function_response_types = ["ReportBatchItemFailures"]` | | Only the failed messages of a batch are retried, not the whole batch |
| `batch_size` 10, window 1 s | | Fewer invocations under load |
| `maximum_concurrency` 3 | | **The account's Lambda concurrency limit is 10 (verified)**. Capping the poller protects the canary and leaves headroom. It is also why there is no reserved concurrency: AWS requires 10 unreserved |
| Encryption | SQS-managed SSE | No CMK by decision |

**Idempotent consumer:** SQS is at-least-once. The handler derives `ticket_id = "<order_id>#<n>"` and writes with `ConditionExpression="attribute_not_exists(ticket_id)"`, so redelivery creates nothing new. Tested with moto (`lambdas/tests`).

**DynamoDB table:** `PK user_id`, `SK ticket_id`, so "my tickets" is a single `Query`. On-demand billing (zero cost when idle), PITR on. Ticketing reads it through the free **DynamoDB gateway endpoint** (no NAT data charge).

**Known gap:** the order event is published **after** the DB commit. If the process dies in between, the order exists but no ticket is issued. The fix is a **transactional outbox** (insert the event in the same transaction and relay it with a poller or CDC). It is documented rather than built, to keep the scope explainable.

## 7. Database and migrations

### 7.1 RDS

| Setting | Value | Why |
|---|---|---|
| Engine | PostgreSQL **18** (major only; AWS picks the default minor, and `auto_minor_version_upgrade` keeps it patched) | Latest major available in eu-west-3 (verified 18.6) |
| Class | `db.t4g.micro` | Graviton burstable, cheapest Multi-AZ-capable class (verified orderable) |
| `multi_az` | true | Synchronous standby in another AZ, automatic failover in about 60-120 s. The connection pool uses `pool_pre_ping` + `pool_recycle=300` so the app reconnects |
| Storage | 20 GB gp3, autoscaling to 50 | gp3: baseline 3000 IOPS regardless of size |
| Backups | `backup_retention_period = 7` | Point-in-time restore to any second in the last 7 days (transaction logs are shipped about every 5 minutes) |
| Deletion protection | **off** | The environment is destroyed after each session |
| `skip_final_snapshot` | true (variable) | Data is demo data. The schema and seed rebuild automatically |
| `delete_automated_backups` | true | Avoids paying for orphaned backups after a destroy |
| Parameter group | `rds.force_ssl=1`, `log_min_duration_statement=500` | Reject plaintext connections; log slow queries to CloudWatch |
| `log_connections` | **removed** | PostgreSQL 18 changed it from a boolean to a list of stages, so `1` would break the apply |
| Performance Insights | on (free 7-day tier) | Top SQL by wait event when latency spikes |
| Subnets | isolated data tier | No route to the internet at all |

**Client TLS:** `DB_SSLMODE=verify-full` with the RDS CA bundle baked into the image at build time (`ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`). `require` would encrypt but would not detect a man-in-the-middle; `verify-full` also checks the certificate chain and the hostname.

### 7.2 One instance, two schemas

Both services use the same RDS instance but **separate schemas** (`identity`, `ticketing`), separate Alembic version tables, and neither service queries the other's schema. That is "logical database per service". The fully isolated version (separate instances or users with schema-level grants) costs about double, or needs a bootstrap SQL step to create users. Documented trade-off.

### 7.3 Migrations at startup, safely

Each service runs `alembic upgrade head` in the FastAPI lifespan, **inside a Postgres advisory lock** (`pg_advisory_lock(7301001)` for identity, `…002` for ticketing). When 2 tasks start together, one migrates and the other waits, then finds nothing to do. That means no separate migration job or Lambda, and no race.

Rules this implies, which you must follow later: migrations must be **backwards-compatible** with the previous app version, because during a rolling deploy old and new tasks run side by side. Use expand/contract: add a nullable column → deploy → backfill → make it required in a later release.

The seed migration (`0002_seed_events`) inserts the demo events with `ON CONFLICT DO NOTHING` and deterministic UUIDv5 ids, so it is idempotent and ids are stable across rebuilds.

## 8. Containers

`services/*/Dockerfile`:

| Line / choice | Why |
|---|---|
| `python:3.14-slim-bookworm` | Matches the local Python, small, glibc (wheels work) |
| Multi-stage: build stage creates `/opt/venv`, runtime copies only the venv | Compilers and pip caches never reach production |
| `build-essential` in the build stage only | Fallback if a dependency lacks a prebuilt ARM64 wheel |
| `useradd --uid 10001`, `USER 10001:10001` | Non-root. The ECS task definition also sets `user` |
| `PYTHONDONTWRITEBYTECODE=1` | No `.pyc` writes, required for `readonlyRootFilesystem` |
| `readonlyRootFilesystem = true` + an ephemeral volume at `/tmp` | An attacker with code execution cannot modify the image's files |
| exec-form `CMD [... "uvicorn" ...]` | uvicorn is PID 1 and receives ECS's SIGTERM directly. `--timeout-graceful-shutdown 20` plus `stopTimeout = 25` lets in-flight requests finish |
| `--proxy-headers --forwarded-allow-ips *` | Behind ALB + CloudFront, trust `X-Forwarded-*` so URLs and scheme are correct. Safe because the SG only admits the ALB |
| 1 uvicorn worker | One process per 0.5 vCPU task. Scale with more tasks, not more workers: cleaner metrics and simpler autoscaling |
| `HEALTHCHECK` in Dockerfile | For local `docker run`. ECS uses the task-definition health check |
| Pinned requirements (`==`) | Reproducible builds. Dependabot proposes bumps |

**Why ARM64:** Fargate Graviton is about 20% cheaper per vCPU-hour, and GitHub provides free native ARM runners (`ubuntu-24.04-arm`) for public repos, so no slow QEMU emulation.

## 9. Frontend and the edge

### 9.1 React SPA

Vite + React 19 + React Router 7. No state library (React context is enough). The API base is relative (`/api/...`) because CloudFront serves both on one origin. Locally, the Vite proxy mimics that (`/api/auth` → :8001, `/api` → :8002).

### 9.2 S3 + CloudFront

- The S3 bucket is **fully private** (all four public-access-block flags, `BucketOwnerEnforced`). CloudFront reads it through **Origin Access Control** (SigV4-signed requests). The bucket policy allows `s3:GetObject` only for the principal `cloudfront.amazonaws.com` **with `AWS:SourceArn` = our distribution**, so another distribution in another account cannot read it.
- **SPA routing:** `/events/123` is not a file in S3. A **CloudFront Function** on the default behavior rewrites any URI without a dot to `/index.html`. Why not `custom_error_response 404 → /index.html`: that applies distribution-wide, so API 404s ("event not found") would come back as HTML 200s.
- **Caching:** the S3 behavior uses `Managed-CachingOptimized`. The pipeline uploads hashed assets with `max-age=31536000, immutable` and `index.html` with `no-cache`, then invalidates only `/index.html` and `/`. The `/api/*` behavior uses `Managed-CachingDisabled` (dynamic, per-user) with `Managed-AllViewerExceptHostHeader`, which forwards cookies, query strings and headers such as `Idempotency-Key`, but **not Host** (the ALB must see its own hostname).
- **Security headers** (response headers policy, both behaviors): HSTS 1 year, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, CSP `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; …; frame-ancestors 'none'`. `'unsafe-inline'` for styles is needed because React sets inline `style` attributes (poster colours). Scripts stay strict.
- `PriceClass_100` (EU + North America edges): cheapest, and fine for the audience.

### 9.3 HTTPS without a domain (the honest part)

- Browser → CloudFront is HTTPS with the default `*.cloudfront.net` certificate, and HTTP redirects to HTTPS.
- CloudFront → ALB is **HTTP**. An ALB can only serve a browser-trusted certificate for a domain you own, and there is no domain by decision.
- Compensating controls that make the ALB effectively private to CloudFront:
  1. The ALB SG admits only the **`com.amazonaws.global.cloudfront.origin-facing` managed prefix list** on port 80. This list counts as many rules against the SG quota (about 55), which is why the ALB has a **dedicated SG**.
  2. CloudFront adds `X-Origin-Verify: <40 random chars>`. ALB listener rules forward only when the header matches, and the default action is a fixed **403**. Someone else's CloudFront distribution would pass check 1 but fail check 2.
- With the default certificate you cannot set the viewer minimum TLS policy (CloudFront applies its own default). Documented and Checkov-skipped.

### 9.4 WAF (regional, on the ALB)

Why on the ALB and not on CloudFront: a CloudFront WAF must be created in `us-east-1`, which needs a second provider alias. A regional ACL keeps one provider. The trade-off is that blocked requests still travel through CloudFront (negligible).

| Rule | Priority | Why |
|---|---|---|
| Rate-based, 2000 req / 5 min **per forwarded IP** | 0 | Behind CloudFront the TCP source IP is a CloudFront edge, so keying on it would rate-limit everyone together. `aggregate_key_type = FORWARDED_IP` on `X-Forwarded-For` (CloudFront puts the client IP first). `fallback_behavior = MATCH` counts requests without the header too |
| `AWSManagedRulesCommonRuleSet` | 10 | OWASP-style baseline (XSS, LFI, size limits…) |
| `AWSManagedRulesKnownBadInputsRuleSet` | 20 | Log4Shell, bad host headers, known exploit paths |
| `AWSManagedRulesSQLiRuleSet` | 30 | SQL injection signatures (defense in depth; the app uses bound parameters everywhere) |

The IP reputation list was **not** added: it judges the source IP, which here is CloudFront, so it would do nothing.

WAF logs go to `aws-waf-logs-ticketrush-prod` (the prefix is mandatory) and are **filtered to BLOCK only** (cheap, which is what you need for false-positive triage), with the `cookie` header **redacted** (session tokens never reach logs).

## 10. Network

`terraform/modules/network`.

| Item | Value | Why |
|---|---|---|
| VPC | `10.0.0.0/16` | 65,536 addresses. Plenty, and RFC 1918 |
| Subnets | `/20` each (4,091 usable after AWS reserves 5) | Fargate gives **every task its own ENI/IP** (awsvpc), so app subnets need room. /20 leaves space for growth and a third AZ |
| Index plan | public 0-1 (`10.0.0.0/20`, `10.0.16.0/20`), app 4-5 (`10.0.64.0/20`, `10.0.80.0/20`), data 8-9 (`10.0.128.0/20`, `10.0.144.0/20`) | Gaps leave room to add AZ 3 or new tiers without renumbering. The tier is readable from the second octet |
| AZs | first 2 from `data.aws_availability_zones` | Never hardcoded, so the region stays portable |
| `map_public_ip_on_launch` | false everywhere | Only the ALB and NAT have public IPs, and they get them explicitly |
| Default SG | emptied (`aws_default_security_group` with no rules) | Nothing can accidentally use the wide-open default |

**Route tables (your networking background, mapped):**

| Tier | Default route | Comparable to |
|---|---|---|
| public | `0.0.0.0/0 → IGW` | A DMZ with a public interface |
| app | `0.0.0.0/0 → NAT` (one table per AZ) | An inside VLAN with PAT/overload to the internet. Outbound only |
| data | **none** (only the implicit `local` route) | A VLAN with no default gateway: unreachable from or to the internet even if misconfigured |

**One NAT vs one per AZ:** one NAT costs about USD 35/month plus data. If its AZ fails, tasks in the *other* AZ lose internet egress (they can still reach RDS, the cache, S3 and DynamoDB through gateway endpoints). They could not pull new images or reach SSM, X-Ray or SQS, so new tasks would not start. `nat_per_az = true` fixes it at double the NAT cost. The route logic already picks a same-AZ NAT if one exists.

**Gateway endpoints (free):** S3 (ECR stores image **layers** in S3, so image pulls skip the NAT data charge) and DynamoDB (ticketing reads tickets). Attached to the app route tables. **Interface endpoints** (ECR API, SSM, logs, SQS, X-Ray…) were skipped: about USD 7-8/month **each per AZ**, so 6-8 of them would cost more than the NAT itself at this scale.

**Security groups vs NACLs:** SGs are **stateful** and attached to ENIs (like a host firewall that tracks connections). NACLs are **stateless** and attached to subnets (like router ACLs, where you must allow return traffic on ephemeral ports). We use SGs that reference other SGs (identity-based: "from the ALB's SG") instead of CIDRs, so rules stay correct as tasks get new IPs. NACLs stay at default (allow all). Adding them would duplicate the SGs and is a classic source of ephemeral-port bugs.

**SG chain:** CloudFront prefix list →(80)→ ALB SG →(8000)→ service SGs →(5432)→ DB SG, and →(6379)→ cache SG. Nothing else is open inbound.

**Flow logs:** ALL traffic to CloudWatch, **10-minute aggregation** (cheaper than 1 minute; fine for forensics), 7-day retention. The IAM role carries the permissions boundary.

## 11. ECS / Fargate

`terraform/modules/ecs-service`.

| Setting | Value | Why |
|---|---|---|
| CPU / memory | 512 / 1024 | Room for argon2 bursts and the ADOT sidecar (64 CPU units / 128 MB). The smallest valid size (256/512) would leave the app about 380 MB |
| `cpu_architecture` | ARM64 | Graviton price |
| Containers | `app` (essential) + `otel-collector` (ADOT, **non-essential**) | If the tracing sidecar dies, the business keeps running. `dependsOn START` so the app starts after the collector |
| Health check | `python -c urllib … /health`, interval 15, retries 3, `startPeriod` 30 | The slim image has no curl. `startPeriod` covers migrations at boot |
| `health_check_grace_period_seconds` | 60 | ECS ignores ALB health for 60 s after a task starts. Too short and slow starts trip the circuit breaker |
| Deployment | min 100%, max 200% | New tasks start **before** old ones stop, so capacity never drops |
| Circuit breaker | enable + rollback | If new tasks keep failing, ECS rolls back to the last healthy revision automatically |
| `enable_execute_command` | true | `aws ecs execute-command` gives a shell through SSM. No SSH, no bastion. Needs `ssmmessages:*` on the **task** role (not the execution role) and internet egress (NAT) because there are no interface endpoints |
| `assign_public_ip` | false | Private subnets |
| Logs | `awslogs`, `mode = non-blocking`, 4 MB buffer | If CloudWatch is slow, logs are dropped rather than the app freezing on stdout |
| `ignore_changes` | `task_definition`, `desired_count` | The **pipeline owns task-definition revisions** (new image per commit) and **autoscaling owns the count**. Without this, every `terraform apply` would roll back the last deploy and reset scaling |
| Target group | `target_type = ip`, `deregistration_delay = 30` | awsvpc tasks register by IP. 30 s drain (default 300) keeps deploys fast; requests are short |
| Autoscaling | target tracking on average CPU 60%, min 2, max 4, scale-out cooldown 30 s, scale-in 120 s | Scale out fast for a drop, scale in slowly to avoid flapping. Min 2 means one task per AZ |
| Container Insights | `enhanced` | Per-task and per-container metrics, restarts, deployment visibility |

**Two IAM roles per service:**

- **Execution role:** used by the ECS agent **before** your code runs: pull from ECR, create log streams, and fetch **only this service's** SSM parameters (`ssm:GetParameters` on exact ARNs). AWS-managed `alias/aws/ssm` keys need no explicit `kms:Decrypt`, because the key policy allows principals in the account via SSM.
- **Task role:** what the **code** can do: X-Ray put, ECS Exec channels, ADOT's EMF log group, plus per-service extras (ticketing: `sqs:SendMessage` on the orders queue, `dynamodb:Query`/`GetItem` on the tickets table; identity: nothing extra).
- Both trust `ecs-tasks.amazonaws.com` with `aws:SourceAccount` = this account (confused-deputy protection) and carry the permissions boundary.

**The image chicken-and-egg:** tags are immutable SHAs, so there is no `latest`. On a fresh environment Terraform must know a real tag. The foundation layer creates SSM `/ticketrush/deploy/<svc>/image_tag` (initial value `none`, `ignore_changes = [value]`). The pipeline writes the SHA after every push, **even when the environment is down**. envs/prod reads it. A `precondition` on the task definition fails with a clear message if it is still `none`.

**Pipeline vs Terraform on the task definition:** `scripts/deploy-service.sh` describes the **latest revision of the family** (which includes Terraform's latest skeleton: env vars, secrets, CPU), swaps only the `app` image, registers a new revision, updates the service, and waits for `services-stable`. It then checks the service is actually running **its** revision. If not, the circuit breaker rolled back, and the job fails. Consequence to remember: a Terraform-only change to the task definition (for example a new env var) creates a new revision but does not roll the service (`ignore_changes`). The next app deploy picks it up, or run App CD manually.

## 12. Secrets

| Secret | Generated by | Stored | Consumed by |
|---|---|---|---|
| DB master password (32 chars, special chars limited to what RDS allows: no `/ @ "` or space) | `random_password` | SSM SecureString `/ticketrush/prod/secrets/db_password` | RDS + both services (`DB_PASSWORD`) |
| JWT signing key (64 chars) | `random_password` | `…/jwt_secret` | both services |
| Valkey AUTH token (48 alphanumerics) | `random_password` | `…/cache_token` | ElastiCache + both services |
| Origin verify header (40 chars) | `random_password` | `…/origin_verify` | CloudFront origin header + ALB rules |

- SSM Parameter Store (not Secrets Manager): free standard parameters; rotation is not needed for an ephemeral env. AWS-managed key `alias/aws/ssm` (no CMK by decision).
- **Injection:** the task definition's `secrets: [{name, valueFrom: <parameter ARN>}]`. ECS resolves them at task start with the execution role. The code just reads env vars and never needs SSM permissions.
- **The honest trade-off:** because Terraform generates the values, they are in the **state file**. Mitigations: the state bucket is private (public access block), versioned, SSE-encrypted, and TLS-only by bucket policy; the plan role can read state (needed for plans), so it is treated as sensitive; and plan output marks these values `(sensitive value)`, so public PR comments leak nothing. Alternatives: `manage_master_user_password` (RDS keeps the password in Secrets Manager, never in state; declined because of the SSM-only rule) or write-only attributes (`password_wo`) in newer providers.
- **gitleaks** runs in CI on full history and as a pre-commit hook. GitHub push protection is the server-side net. `.gitignore` excludes `.env*`, `*.tfvars`, `*.tfstate*`, keys and `.aws/`.

## 13. IAM and the CI roles

`terraform/foundation/iam.tf`.

**OIDC trust:** `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`, and `sub` matched with **StringEquals** (not `StringLike` with wildcards):

| Role | Allowed `sub` | Meaning |
|---|---|---|
| `ticketrush-gha-plan` | `repo:<owner>/<repo>:pull_request` | Any PR in this repo (fork PRs get no OIDC token by default) |
| `ticketrush-gha-apply` | `repo:<owner>/<repo>:ref:refs/heads/main` | Only workflows running on `main` |
| `ticketrush-gha-deploy` | same | Only `main` |

**Plan role:** `ReadOnlyAccess` plus state read plus `PutObject`/`DeleteObject` on `*.tflock` only, because S3 native locking writes a lock object next to the state. The alternative was `-lock=false` on plans, but a plan racing an apply could then read half-written state.

**Apply role:** `PowerUserAccess` (everything **except** IAM, Organizations and Account) plus a scoped inline IAM policy:

- `CreateRole`, `PutRolePolicy`, `AttachRolePolicy`… only on `role/ticketrush-*` **and only if** `iam:PermissionsBoundary` = `ticketrush-workload-boundary`.
- Explicit **Deny** on the CI roles themselves (`ticketrush-gha-*`) and on the boundary policy, plus `DeleteRolePermissionsBoundary` denied everywhere.
- **Why it matters:** "can create IAM roles" normally equals "can become admin" (create a role with AdministratorAccess and assume it). The boundary is a ceiling intersected with whatever policy the role gets, and it denies `iam:*`, `organizations:*`, `account:*` and `sts:AssumeRole`. Even a compromised pipeline can only create roles that cannot touch IAM.
- Honest note: PowerUser is broader than strictly needed (for example it allows services this stack never uses). The next tightening step is to generate a policy from CloudTrail with IAM Access Analyzer after a few applies. Least privilege is iterative.

**Deploy role:** ECR push on the two repos only; `ecs:UpdateService` on `service/ticketrush-*/*`; Describe/Register (these actions do not support resource-level permissions); `iam:PassRole` on `role/ticketrush-prod-*` **only when passed to `ecs-tasks.amazonaws.com`**; SSM read on `/ticketrush/env/*` and write on `/ticketrush/deploy/*`; S3 on `ticketrush-*-frontend-*`; CloudFront invalidations.

**Workload roles in envs/prod** (task, execution, Lambda, flow logs) all set `permissions_boundary`, which is enforced by the apply role's condition, so forgetting it fails the apply.

## 14. Terraform structure

| Choice | Why |
|---|---|
| 3 layers (bootstrap / foundation / envs/prod) | Different lifetimes. You can destroy prod daily without losing state, images, roles or GitHub wiring |
| Partial backend config (`-backend-config=bucket=…`) | No account ID committed. The Makefile computes it, and CI uses `TF_STATE_BUCKET` |
| `use_lockfile = true` | S3 native locking (Terraform ≥ 1.10). No DynamoDB lock table to pay for or manage |
| Bootstrap starts with local state, then `-migrate-state` | The bucket cannot store the state of its own creation until it exists |
| `prevent_destroy` on the state bucket | `terraform destroy` in bootstrap cannot delete your state by accident |
| Provider `~> 6.72` (verified latest 6.72.0), lock files committed | Reproducible provider builds. Patch and minor updates through Dependabot |
| `default_tags` (Project, Environment, ManagedBy, Layer) | Cost allocation and "who made this?" |
| Hand-written modules, not community ones | Every line is explainable in an interview. Kept small: network, ecs-service, lambda-fn. Root files are split by concern (`alb.tf`, `edge.tf`, `data.tf`…) |
| `for_each` with maps (subnets keyed `app-eu-west-3a`) | Stable addresses: removing an item does not renumber the others (unlike `count`) |
| No provisioners, minimal `depends_on` | Declarative only |
| `archive_file` for Lambda zips | Code change → plan shows a new hash → apply. No build step, no S3 artifact bucket |
| `nonsensitive()` on the image-tag SSM value | `aws_ssm_parameter` values are always marked sensitive; a commit SHA is not secret, and hiding it would make plans unreadable |

**`terraform test` (9 tests, all passing locally):** `mock_provider "aws"` with `command = plan`, so tests cost nothing, need no credentials and run in seconds.

- network: 6 subnets, exactly 1 NAT by default, 2 NATs with `nat_per_az`, no public IP auto-assignment, exact subnet CIDR plan, `az_count = 1` rejected by validation.
- ecs-service: circuit breaker + rollback, min healthy 100%, no public IP, read-only root fs, ARM64, secrets injected through `secrets`, both roles carry the boundary, and the `:none` image placeholder is refused.

Limitation of mocks: computed attributes (ARNs, IDs) are fake, so tests assert **configuration intent**, not AWS behaviour. Real behaviour is verified by the apply and the smoke test.

## 15. CI/CD

| Detail | Why |
|---|---|
| `permissions: contents: read` at workflow level, `id-token: write` only where AWS is needed | Least privilege for `GITHUB_TOKEN` |
| Actions pinned to exact versions (verified latest) | Reproducible. Dependabot updates them. Pinning to commit SHAs would be the stricter next step |
| Path filters + dynamic matrix (`dorny/paths-filter`) | A change in `services/identity` rebuilds only identity. Shared files (the deploy script, the workflow) rebuild everything |
| `ubuntu-24.04-arm` runners | Native ARM64 builds, free on public repos |
| BuildKit cache `type=gha` scoped per service | Dependency layers are reused, so rebuilds take seconds |
| Image tag = `github.sha`, ECR `IMMUTABLE` | Every running container maps to an exact commit, and nobody can overwrite a deployed tag. Re-running a workflow detects the existing tag and skips the push instead of failing |
| `provenance: false` | Keeps a single-arch image manifest, the simplest for ECS and ECR lifecycle |
| Environment-down detection | If `/ticketrush/env/cluster` does not exist, push images and skip the deploy with a notice. The pipeline stays green after a destroy |
| `concurrency: app-deploy` / `terraform-prod`, `cancel-in-progress: false` | Never two deploys or applies at once, and never kill one halfway |
| Plan on PR only for same-repo PRs | Forks cannot assume AWS roles anyway; this avoids red checks |
| Apply guarded by `ENV_ACTIVE` | Merging Terraform after a destroy must not silently recreate a USD 6/day environment |
| `ALERT_EMAIL` as a **secret** | GitHub variables are printed in plain text in logs, and logs of a public repo are public |
| Smoke test with retries through CloudFront | Proves the whole path (edge → WAF → ALB → task → DB) and checks the HSTS header |
| CI tests against real Postgres/Valkey service containers | The concurrency test needs real row locking, which SQLite cannot reproduce |

## 16. Observability

- **Logs:** JSON lines (`ts, level, logger, msg, method, path, status, duration_ms`), with uvicorn's access log disabled (we log requests ourselves with timing). 14-day retention (7 for flow, WAF and canary logs).
- **Saved Logs Insights queries:** top errors, slowest requests, and latency percentiles by route (`pct(duration_ms, 99)`).
- **Traces:** the OTel SDK is configured only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (so local runs need no collector). It uses the `AwsXRayIdGenerator` (X-Ray needs time-based trace IDs) and the X-Ray propagator. Instrumented: FastAPI, SQLAlchemy, Redis, botocore. 20% parent-based sampling (`OTEL_TRACES_SAMPLER_ARG=0.2`). Export is OTLP/gRPC to `localhost:4317`, where the ADOT sidecar (`aws-otel-collector:v0.51.0`, verified latest) uses its default ECS config and exports to X-Ray. Lambdas use X-Ray active tracing.
- **Metrics:** AWS-native (ALB, ECS, RDS, ElastiCache, SQS, Lambda, WAF, CloudFront, NAT) plus EMF custom metrics (`TicketRush/Business`, `TicketRush/Canary`). Custom metrics cost about USD 0.30/month each, so dimensions are kept low-cardinality (Service, Check, Resource; never user or event IDs).

**The dashboard** (`dashboard.tf`), row by row:

1. **Scoreboard:** availability % (metric math: `100 - 100 × 5xx / requests`), canary success per check, tickets sold / revenue / sold-out rejections, and an alarm status widget.
2. **Traffic / errors / latency:** requests per service, status classes (2xx/4xx/target 5xx/ALB 5xx; the split tells "my code" from "the load balancer"), p50/p90/p95/p99 with a horizontal **SLO annotation**.
3. **Saturation:** CPU and memory per service, healthy tasks behind the ALB.
4. **Data tier:** RDS CPU + connections, read/write latency, cache hit ratio (computed from EMF hit/miss) + Valkey memory.
5. **Async:** queue depth, DLQ depth, oldest message age, Lambda invocations/errors/throttles, canary latency from outside.
6. **Edge and network:** WAF allowed vs blocked, CloudFront requests and error rates (the widget queries **us-east-1**, because CloudFront metrics only live there), NAT bytes and port-allocation errors.
7. **Logs:** slowest requests and errors by message (Logs Insights widgets).

**Alarms** (all → SNS → email, each description names its runbook):

| Alarm | Condition | Why this threshold |
|---|---|---|
| `alb-5xx-rate` | (ELB+target 5xx)/requests > 2%, 2 of 3 minutes | A **rate**, so low traffic does not page on 1 error; 2 of 3 filters single-minute blips |
| `alb-p99-latency` | p99 > `slo_latency_p99_ms` (800 ms) for 3 min | Tied to the SLO variable |
| `<svc>-unhealthy-targets` | UnHealthyHostCount > 0 for 3 min | Early warning |
| `<svc>-no-healthy-targets` | HealthyHostCount < 1 for 2 min, **missing = breaching** | The service is down. Missing data here means something is very wrong |
| `rds-cpu`, `rds-free-storage` | > 80% for 3 min; < 2 GiB | Saturation |
| `cache-memory` | > 85% | Evictions next |
| `orders-dlq-not-empty` | > 0 | Every DLQ message is an unissued ticket |
| `orders-oldest-message` | > 120 s | The consumer is stuck even if nothing failed yet |
| `issuer-errors` | > 0 | |
| `canary-failing` | events_api success < 1 for 3 min, **missing = breaching** | If the canary itself stops, that is also an outage signal |
| `nat-port-allocation` | > 0 | NAT exhaustion causes silent connection failures |
| **`USER-IMPACT` (composite)** | canary failing **AND** (5xx rate OR any service with no healthy targets) | The one alarm worth waking up for: user-visible and confirmed server-side |

`ok_actions` are set too, so you also get the "resolved" email (useful for MTTR measurement).

**External canary:** a Lambda every minute (EventBridge) probes `/`, `/api/events`, `/api/auth/health` and `/api/health` through the **public CloudFront URL**, from outside the VPC, and emits `Success` and `LatencyMs` per check via EMF. This is the **availability SLI** to build SLOs on: an `availability = avg(Success)` SLO of `slo_availability_target` (99.5% allows about 3.6 h/month of downtime), and burn-rate alarms at 14.4x over 1 h and 6x over 6 h (Google SRE workbook multi-window pattern).

## 17. Security scanning and skipped checks

Local results at commit time: **Checkov 487 passed / 0 failed / 89 skipped**, TFLint clean, gitleaks "no leaks found", ruff clean, and **15 service tests + 3 Lambda tests + 9 Terraform tests passing**.

Every skip is an inline `#checkov:skip=ID:reason` next to the resource. Categories:

| Category | Checks (examples) | Reason |
|---|---|---|
| No customer-managed KMS keys | CKV_AWS_158, 145, 136, 119, 191, 337, 26 | Project decision: AWS-managed keys only. SNS alerts topic: CloudWatch cannot publish to a topic encrypted with the AWS-managed SNS key |
| Ephemeral environment | CKV_AWS_293, 150, 338, 21 | No deletion protection, short log retention, no versioning on rebuildable assets |
| No domain | CKV_AWS_2, 103, 378, 174, CKV2_AWS_20, 42, 74 | HTTP on the CloudFront→ALB hop, default certificate. See 9.3 |
| WAF placement | CKV_AWS_68, CKV2_AWS_47, 28, 76 | Regional WAF on the ALB, with Log4j rules via KnownBadInputs |
| Cost | CKV_AWS_91, 86, 18, 118, 144 | ALB/CloudFront/S3 access logs, enhanced monitoring, cross-region replication |
| Declined features | CKV_AWS_163, 272 | Image scanning and code signing were explicitly declined |
| Lambda | CKV_AWS_117, 116, 115, 173 | Not in a VPC (calls only public AWS APIs), DLQ on the queue not the function, no reserved concurrency (account limit 10) |
| Permissions boundary | CKV_AWS_1, 49, 107-111, 356 | The boundary is a ceiling, not a grant |
| False positives | CKV_AWS_260, CKV2_AWS_34, 32 | Prefix-list source, non-secret SSM strings, the headers policy is attached |

Checkov's HCL parser could not read heredocs that contain `|` (the Logs Insights queries), so those queries are built with `join("\n", [...])`. Terraform was fine either way, but a file Checkov cannot parse is a file it silently does not scan.

## 18. Cost

Estimates for eu-west-3 (Infracost on PRs gives exact numbers once its API key is set):

| Item | Driver | Lever |
|---|---|---|
| NAT gateway | about USD 0.05/h + USD 0.05/GB | One NAT; S3/DynamoDB gateway endpoints |
| Fargate | 4 tasks × (0.5 vCPU + 1 GB) ARM | `service_desired_count = 1` halves it (loses the AZ redundancy story) |
| RDS Multi-AZ | 2 × db.t4g.micro | `db_multi_az = false` halves it |
| ALB | hourly + LCU | |
| ElastiCache | 1 × cache.t4g.micro | `cache_replicas` |
| WAF | USD 5/ACL/month + USD 1/rule/month + requests, prorated | |
| Public IPv4 | USD 0.005/h per address (NAT EIP + ALB nodes) | |
| CloudWatch | logs ingestion, about 10 custom metrics, dashboards (3 free), alarms (USD 0.10 each), Container Insights enhanced | Short retention, low cardinality |

Roughly **USD 0.25-0.30/hour**. A 4-hour session costs about USD 1.2, so the USD 50-100 budget allows a lot of sessions. Budgets **alert, they do not stop spending**: `make destroy` + `make verify-clean` is the real control.

## 19. Known limitations and next steps

| Limitation | Next step |
|---|---|
| Event published after commit (tiny loss window) | Transactional outbox table + relay |
| HS256 shared secret | RS256: identity signs, publishes JWKS, ticketing verifies with the public key only |
| No refresh tokens / revocation | Refresh token rotation + `jti` deny-list in Valkey |
| PowerUser on the apply role | CloudTrail → IAM Access Analyzer generated policy |
| Shared RDS instance | Per-service DB users with schema grants (bootstrap SQL), then separate instances |
| HTTP origin hop | Buy a domain: ACM cert on the ALB, `https-only` origin |
| SLOs only as variables | `aws_cloudwatch_metric_alarm` burn-rate pairs on canary success; consider CloudWatch Application Signals SLOs |
| No load test at scale | k6 or Locust from a separate region; FIS experiments (kill tasks, RDS failover, inject latency) |
| Rolling deploys only | ECS native blue/green (CodeDeploy not needed anymore) with bake time and alarm-based rollback |
| Actions pinned by tag | Pin by commit SHA |

## 20. Interview cheat-sheet

- **"How do you prevent overselling?"** One conditional UPDATE: Postgres row lock + re-check of the WHERE clause, a CHECK constraint as the last line, and a test with 40 concurrent buyers.
- **"What if the user clicks twice?"** Idempotency-Key, a unique constraint, return the original order, and handle the race through IntegrityError.
- **"What if Redis dies?"** Everything fails open to Postgres with a 0.5 s timeout. The cache is an optimisation, never the source of truth.
- **"What if a deploy is bad?"** Health checks fail, the circuit breaker rolls back, and the pipeline detects that the running revision is not ours and goes red. Users never see it (min healthy 100%).
- **"What if an AZ dies?"** 2 tasks across 2 AZs and ALB health checks reroute. RDS fails over to its standby (60-120 s), and the pool's pre-ping reconnects. Caveat: the single NAT (and the fix).
- **"How do secrets reach the container?"** SSM SecureString, the task definition `secrets` field, the execution role. Code reads env vars and never sees SSM.
- **"How does GitHub get into AWS?"** OIDC: a short-lived token whose `sub` is pinned per role (PR → read-only, main → apply). No keys stored anywhere.
- **"Why can't your pipeline become admin?"** Permissions boundary + an IAM condition requiring it on every created role + explicit denies on the CI roles.
- **"How do you know users are OK?"** External canary through CloudFront every minute → availability SLI → composite USER-IMPACT alarm → runbook.
