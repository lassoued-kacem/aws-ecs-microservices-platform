# What to do manually (in order)

Everything in this repo is code, except the glue below: accounts, clicks, and a few one-time commands. Do the steps **in order**. Each step ends with a **Check** so you know it worked before moving on.

Time needed: about 1h15, of which about 25 minutes is waiting for AWS to create the database.

> Cost reminder: steps 1 to 7 cost cents. **Step 8 starts hourly billing** (about USD 0.25 to 0.35 per hour, see README). Step 13 stops it.

---

## 0. Values you will need (write them down as you go)

| Name | Where it comes from | Example |
|---|---|---|
| `GITHUB_USER` | your GitHub username | `lassoued-kacem` |
| `REPO` | the repo you create in step 2 | `ticketrush` |
| `ALERT_EMAIL` | your email for alarms and budget alerts | you@example.com |
| `STATE_BUCKET` | output of step 4 | `ticketrush-tfstate-123456789012-eu-west-3` |
| 4 role ARNs + registry | output of step 5 | `arn:aws:iam::...:role/ticketrush-gha-plan` |

The region is `eu-west-3` everywhere. To use another region, replace it in every command and in the `AWS_REGION` GitHub variable.

---

## 1. Local tools (once)

Already on your machine: git, Terraform 1.16.5, AWS CLI 2, Node 22, Python 3.14, podman. The session that built this repo also installed `checkov` (user pip), `tflint` and `gitleaks` (into `~/.local/bin`).

```bash
# Docker: the daemon was not running. Either start it...
sudo systemctl enable --now docker && sudo usermod -aG docker $USER   # log out and back in afterwards
# ...or keep using podman (compose works with: podman compose up --build)

# Python venv for local tests
cd "<repo>"
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt

# Git hooks (gitleaks + ruff + terraform fmt run before every commit)
.venv/bin/pre-commit install

# Optional: Session Manager plugin, needed for `aws ecs execute-command` (shell into a container)
sudo dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
```

**Check:** `terraform version`, `aws --version`, `.venv/bin/pytest --version` all print versions.

### 1b. Optional: run the whole thing locally first

```bash
docker compose up --build -d          # postgres, valkey, identity:8001, ticketing:8002
cd frontend && npm ci && npm run dev  # http://localhost:5173
```

**Check:** open http://localhost:5173, create an account, buy a ticket. Tickets stay "Issuing…" locally because SQS and Lambda only exist in AWS. That is expected.

---

## 2. GitHub repository

### 2.1 Push access with an SSH key (skip if `ssh -T git@github.com` already greets you)

```bash
ssh-keygen -t ed25519 -C "your-email" -f ~/.ssh/id_ed25519   # set a passphrase
cat ~/.ssh/id_ed25519.pub
```

GitHub → avatar → **Settings → SSH and GPG keys → New SSH key**. Paste the key and save.

**Check:** `ssh -T git@github.com` prints "Hi GITHUB_USER! You've successfully authenticated".

### 2.2 Create the repo and push

GitHub → **New repository** → name `ticketrush` → **Public** → do **not** add a README, .gitignore or license (the repo already has them) → Create.

```bash
cd "<repo>"
git remote add origin git@github.com:GITHUB_USER/ticketrush.git
git push -u origin main
```

**Check:** the code is visible on GitHub. The **CI** workflow starts. It should pass. Infra and App CD will not run yet (or will fail fast) because the variables do not exist yet.

### 2.3 Repository settings (security)

| Where (repo → Settings) | Set |
|---|---|
| **Actions → General → Workflow permissions** | "Read repository contents and packages permissions" (read-only default) |
| **Actions → General → Fork pull request workflows from outside collaborators** | "Require approval for all outside collaborators" |
| **Advanced Security** (or "Code security") | Enable **Secret Protection / Secret scanning** and **Push protection** |
| **Advanced Security** | Enable **Dependabot alerts** and **Dependabot security updates** |
| **Branches → Add branch ruleset** (recommended) | Target `main`: require a pull request, and require status checks `Python lint + tests`, `Frontend build`, `Secret scan (gitleaks)`, `fmt / validate / tflint / checkov / test` |

Why: the repo is public. These settings stop forks from running workflows unasked, block pushes that contain secrets, and force every change through CI.

---

## 3. AWS account sanity (once)

```bash
aws sts get-caller-identity          # must show your IAM user, NOT root
aws configure get region             # set it with: aws configure set region eu-west-3
```

- Turn on **MFA** for your IAM user: Console → IAM → Users → you → Security credentials → Assign MFA device.
- Never commit `~/.aws`. It is outside the repo and also in `.gitignore`.
- If you use a named profile (for example `flagship`), run `export AWS_PROFILE=flagship` in every terminal you use for this project.

**Check:** `aws sts get-caller-identity` returns your account ID.

---

## 4. Bootstrap layer: state bucket + budget (once, permanent, about USD 0/month)

```bash
export TF_VAR_alert_email="you@example.com"     # never written to any file
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars     # optional: change monthly_budget_usd (default 60)
terraform init
terraform apply                                  # review the plan: 8 resources, type yes
terraform output state_bucket                    # write this down as STATE_BUCKET
```

Then move the bootstrap layer's own state into the bucket it just created, so it is not lost if your laptop dies:

```bash
cp backend.tf.example backend.tf
terraform init -migrate-state -backend-config="bucket=$(terraform output -raw state_bucket)" -backend-config="region=eu-west-3"
# answer "yes" to copy the state
rm -f terraform.tfstate terraform.tfstate.backup
cd ../..
```

`backend.tf` is safe to commit (it holds no account data). Commit it: `git add terraform/bootstrap/backend.tf && git commit -m "chore: bootstrap state in S3" && git push`.

**Check:** `aws s3 ls s3://STATE_BUCKET/bootstrap/` lists `terraform.tfstate`. AWS Budgets → `ticketrush-monthly` exists. Budget emails need no confirmation click.

---

## 5. Foundation layer: ECR, GitHub OIDC, CI roles (once, permanent, cents/month)

First check whether your account already has the GitHub OIDC provider. Only one is allowed per account:

```bash
aws iam list-open-id-connect-providers   # if it lists token.actions.githubusercontent.com -> set create_oidc_provider = false below
```

```bash
cd terraform/foundation
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars:
#   github_repository = "GITHUB_USER/ticketrush"      <- must match EXACTLY (case-sensitive)
#   state_bucket      = "STATE_BUCKET"
#   create_oidc_provider = false                      <- only if the provider already existed
terraform init -backend-config="bucket=STATE_BUCKET" -backend-config="region=eu-west-3"
terraform apply
terraform output github_variables    # copy these values for step 6
cd ../..
```

**Check:** ECR shows `ticketrush/identity` and `ticketrush/ticketing` (immutable tags). IAM shows the roles `ticketrush-gha-plan`, `ticketrush-gha-apply`, `ticketrush-gha-deploy` and the policy `ticketrush-workload-boundary`.

---

## 6. GitHub Actions variables and secrets

Repo → **Settings → Secrets and variables → Actions**.

**Variables** tab (not secret, visible to collaborators):

| Name | Value |
|---|---|
| `AWS_REGION` | `eu-west-3` |
| `AWS_ROLE_PLAN_ARN` | from `github_variables` output |
| `AWS_ROLE_APPLY_ARN` | from `github_variables` output |
| `AWS_ROLE_APP_DEPLOY_ARN` | from `github_variables` output |
| `TF_STATE_BUCKET` | `STATE_BUCKET` |
| `ENV_ACTIVE` | `false` (switch to `true` in step 10) |

**Secrets** tab:

| Name | Value | Required? |
|---|---|---|
| `ALERT_EMAIL` | your email | **Yes**. It is a secret, not a variable, so it is masked in public logs |
| `INFRACOST_API_KEY` | see below | Optional. Without it, the Infracost PR comment is skipped |

To get an Infracost key: sign up at https://dashboard.infracost.io (free), go to Org settings → API key, and copy it.

**Check:** the 6 variables and at least 1 secret are listed.

---

## 7. Push the first images (environment still down, costs cents)

Terraform refuses to create the ECS services until an image exists. This is deliberate: there is no `latest` tag, only immutable commit SHAs.

GitHub → **Actions → App CD → Run workflow** → branch `main` → tick **force_all** → Run.

The workflow builds both images natively on an ARM runner, pushes `:<commit-sha>`, and writes the tag to SSM `/ticketrush/deploy/<service>/image_tag`. It then reports "Environment is down: deploy skipped". That is the expected result.

**Check:**

```bash
aws ssm get-parameter --name /ticketrush/deploy/identity/image_tag  --query Parameter.Value --output text   # a 40-char SHA, not "none"
aws ssm get-parameter --name /ticketrush/deploy/ticketing/image_tag --query Parameter.Value --output text
```

If the run fails at "Configure AWS credentials" with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, `github_repository` in step 5 does not match the repo exactly. Fix the tfvars and run `terraform apply` again.

---

## 8. Create the environment (HOURLY BILLING STARTS)

Pick **one** of the two options.

**Option A, from your laptop** (easiest to watch):

```bash
export TF_VAR_alert_email="you@example.com"
make plan          # read it: roughly 120 resources to add
make apply         # type yes. About 20-25 min (RDS Multi-AZ is the slow part)
make outputs       # app_url, dashboard_url, alb_dns_name
```

**Option B, from GitHub:** Actions → **Infra** → Run workflow → action = `apply`.

Then:

- **Confirm the SNS subscription.** You get an email "AWS Notification - Subscription Confirmation". Click **Confirm subscription**, or you will never receive alarms.

**Check:** `make outputs` prints an `app_url` like `https://dxxxx.cloudfront.net`. Opening it now gives an error page because the frontend bucket is still empty. Step 9 fixes that.

---

## 9. Deploy the frontend and roll the services

GitHub → Actions → **App CD** → Run workflow → **force_all** ticked.

This time the environment is up. It uploads the React build to S3, invalidates CloudFront, deploys both services through `scripts/deploy-service.sh` (and waits for stability), then smoke-tests through CloudFront.

**Check:**

```bash
URL=$(cd terraform/envs/prod && terraform output -raw app_url)
curl -s $URL/api/health                                      # {"status":"ok",...,"cache":"ok"}
curl -sI $URL | grep -i -E 'strict-transport|content-security|x-frame'
curl -s -o /dev/null -w '%{http_code}\n' http://$(cd terraform/envs/prod && terraform output -raw alb_dns_name)/api/events
#   -> 403 (or a timeout). The ALB only accepts CloudFront's secret header from CloudFront IP ranges.
```

Open `$URL` in a browser. Create an account, buy tickets, and go to **My tickets**. The ticket codes appear within a few seconds (SQS → Lambda → DynamoDB).

---

## 10. Turn on apply-on-merge

Set the GitHub variable `ENV_ACTIVE` = `true`. From now on, merging a PR that touches `terraform/**` applies automatically. With `false`, merges only run checks and never recreate a destroyed (paid) environment by accident.

---

## 11. Show it off: generate data, take screenshots, measure

```bash
make load URL=$URL                 # 60 buyers race for the 10-seat "Flash Drop", then 2 min of browsing
```

Then, in the AWS console (region eu-west-3):

| What | Where | Screenshot for README |
|---|---|---|
| SRE dashboard | CloudWatch → Dashboards → `ticketrush-prod-sre` (or `make outputs` → dashboard_url) | yes |
| Distributed traces | CloudWatch → X-Ray traces → **Trace Map** | yes |
| Logs Insights saved queries | CloudWatch → Logs Insights → Saved queries → `ticketrush-prod/*` | optional |
| Alarms | CloudWatch → Alarms (all should be OK, except `canary-failing` during the first 3 minutes) | optional |
| WAF | WAF & Shield → Web ACLs (region eu-west-3) → `ticketrush-prod` | optional |

Record the real numbers in `docs/METRICS.md`.

### Resilience demos (great interview stories)

| Demo | How | What you should see |
|---|---|---|
| Self-healing | `aws ecs list-tasks --cluster ticketrush-prod --service-name ticketing`, then `aws ecs stop-task --cluster ticketrush-prod --task <arn>` | ECS starts a replacement. The site stays up (2 tasks across 2 AZs). Time it |
| Automatic rollback | On a branch, make `/health` in `services/ticketing/app/main.py` return 500. Merge the PR | The deploy fails health checks, the circuit breaker rolls back, App CD goes red with "rolled back". Users notice nothing. Then revert |
| Alert pipeline | `aws cloudwatch set-alarm-state --alarm-name ticketrush-prod-orders-dlq-not-empty --state-value ALARM --state-reason test` | An email arrives |
| DB failover | `aws rds reboot-db-instance --db-instance-identifier ticketrush-prod --force-failover` | About 1-2 min of errors at most, then recovery (`pool_pre_ping` reconnects) |
| WAF | `for i in $(seq 1 3000); do curl -s -o /dev/null $URL/api/events; done` | After about 2000 requests in 5 min you get 403s, and the dashboard shows the blocked spike |
| Shell into a container | `aws ecs execute-command --cluster ticketrush-prod --task <arn> --container app --interactive --command "/bin/sh"` | Needs the session-manager-plugin. No SSH or bastion anywhere |

---

## 12. Day-to-day workflow (after setup)

```bash
git switch -c feat/something
# ...edit...
git commit -am "feat: something" && git push -u origin feat/something
# open a PR -> CI runs tests; Infra posts a terraform plan (+ Infracost) as a PR comment
# merge -> App CD builds only the changed service(s) and deploys them; Infra applies if ENV_ACTIVE=true
```

---

## 13. Destroy at the end of every session (STOPS BILLING)

**Option A:** `make destroy` (type `destroy-prod`). **Option B:** Actions → **Destroy environment** → type `destroy-prod`.

Then:

1. Set the GitHub variable `ENV_ACTIVE` = `false`.
2. Run `make verify-clean`. Every line must be empty. CloudFront distributions take 5-15 minutes to fully disappear, which is normal.

What survives the destroy: the state bucket, the budget, the ECR images, the image-tag pointers, the OIDC roles, and the GitHub configuration. What is lost: database rows, cache, and issued tickets. The schema and the demo events are recreated automatically on the next start.

**To rebuild later:** steps 8 and 9 only, about 30 minutes.

---

## 14. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make apply`: "No image has been pushed for identity yet" | Step 7 not done | Run App CD with force_all |
| Plan fails: `data.aws_iam_policy.boundary` not found | Foundation not applied, or applied in another region | Step 5 |
| Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `github_repository` mismatch, or the workflow ran from a branch other than `main` (apply/deploy roles trust `main` only) | Fix the tfvars and re-apply foundation, or run from `main` |
| Infra PR plan: AccessDenied writing `.tflock` | The plan role can only write `*.tflock` objects | Make sure `TF_STATE_BUCKET` is the bootstrap bucket |
| `terraform init`: "Backend configuration changed" | You switched buckets or regions | `terraform init -reconfigure -backend-config=...` |
| Site shows "AccessDenied" XML | Frontend not uploaded yet | Step 9 |
| `/api/*` returns 403 `{"detail":"forbidden"}` through CloudFront | The ALB rule did not match the origin header (secret rotated?) | Run `make apply` again; it re-syncs CloudFront and the ALB |
| Tasks keep restarting, circuit breaker trips | App crash. Check logs: CloudWatch → Log groups → `/ecs/ticketrush-prod-<svc>` | Usually DB or cache connectivity. See `docs/runbooks/failed-deployment.md` |
| No alarm emails | SNS subscription not confirmed | Click the link from step 8. Resend it with `make apply` after deleting the pending subscription |
| Tickets stuck on "Issuing…" | Lambda or SQS problem | `docs/runbooks/async-backlog.md` |
| `terraform destroy` hangs on subnets or SGs | Lambda/ECS ENIs still detaching | Wait 5-10 min and run destroy again |
| Budget alert email | You hit 50/80/100% of the monthly budget | Destroy if nothing is running on purpose |
