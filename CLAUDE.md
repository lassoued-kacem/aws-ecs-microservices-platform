# CLAUDE.md: agent context for TicketRush

Read `README.md`, `WHAT-TO-DO-MANUALLY.md` and `docs/DEEP-DIVE.md` before changing anything.

## What this is
Flash-sale ticketing platform (resume flagship for cloud/DevOps/SRE roles). Two FastAPI services (`services/identity`, `services/ticketing`), React SPA (`frontend`), two Python Lambdas (`lambdas/`), Terraform in `terraform/{bootstrap,foundation,envs/prod,modules}`, GitHub Actions in `.github/workflows`.

## Safety rules (non-negotiable)
- Never run `terraform apply`/`destroy` or mutating AWS CLI commands without explicit approval in the same turn. `init/validate/fmt/plan/test` and read-only AWS calls are fine.
- Never print or commit secret values. Nothing account-specific (account ID, email, ARNs) is committed; the region is a variable.
- The repo is PUBLIC. `ALERT_EMAIL` is a GitHub secret; the local equivalent is `TF_VAR_alert_email`.
- Remind the owner to destroy `envs/prod` after sessions (it bills about USD 0.25-0.30/h).
- Declined, do not add: image scanning/signing/SBOM, CMKs, Secrets Manager, Fargate Spot, PR preview envs, buying a domain.

## Conventions
- Python: ruff (config `ruff.toml`), pinned requirements, tests need Postgres + Valkey (`docker compose up postgres valkey`).
- Terraform: `~> 6.72` AWS provider, hand-written modules, `terraform test` with mock providers, every Checkov skip inline with a reason, every workload IAM role carries `permissions_boundary`.
- Pipeline owns ECS task-definition revisions (`ignore_changes`); Terraform owns the skeleton.
- Commits: conventional commits, small and frequent.

## Useful commands
`make help` · `make test` · `make lint` · `make plan` · `make apply` · `make destroy` · `make verify-clean` · `make load URL=...`

## Open items the owner plans to add
SLOs + burn-rate alarms, chaos (FIS) and load tests, blue/green, transactional outbox, RS256 JWT.
