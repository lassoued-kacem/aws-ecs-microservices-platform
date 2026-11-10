# TicketRush: common commands. Run `make help`.
# Requires: AWS_PROFILE (or default creds), TF_VAR_alert_email exported.
SHELL := /bin/bash
REGION ?= eu-west-3
PROJECT := ticketrush
ACCOUNT = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET ?= $(PROJECT)-tfstate-$(ACCOUNT)-$(REGION)
BACKEND = -backend-config=bucket=$(STATE_BUCKET) -backend-config=region=$(REGION)
export TF_VAR_region := $(REGION)

.PHONY: help venv test lint local-up local-down fe-dev bootstrap foundation init plan apply destroy outputs verify-clean load

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

venv: ## Create .venv with all Python deps
	python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt

lint: ## ruff + terraform fmt check + checkov
	.venv/bin/ruff check . && .venv/bin/ruff format --check .
	terraform fmt -check -recursive terraform
	checkov -d terraform --framework terraform --quiet --compact

test: ## Unit tests (needs `make local-up` for Postgres/Valkey) + terraform test
	cd services/identity && ../../.venv/bin/python -m pytest -q
	cd services/ticketing && ../../.venv/bin/python -m pytest -q
	.venv/bin/python -m pytest -q lambdas/tests
	cd terraform/modules/network && terraform init -backend=false >/dev/null && terraform test
	cd terraform/modules/ecs-service && terraform init -backend=false >/dev/null && terraform test

local-up: ## Run the full backend locally (docker compose)
	docker compose up --build -d

local-down: ## Stop the local stack
	docker compose down -v

fe-dev: ## Frontend dev server on http://localhost:5173
	cd frontend && npm ci && npm run dev

bootstrap: ## (once) State bucket + budget, local state
	cd terraform/bootstrap && terraform init && terraform apply

foundation: ## (once) ECR, OIDC, CI roles
	cd terraform/foundation && terraform init $(BACKEND) && terraform apply

init: ## Init envs/prod against the remote state
	cd terraform/envs/prod && terraform init $(BACKEND)

plan: init ## Plan envs/prod
	cd terraform/envs/prod && terraform plan -out=tfplan

apply: init ## Create/update envs/prod (BILLS HOURLY)
	cd terraform/envs/prod && terraform apply

destroy: init ## Destroy envs/prod (asks for confirmation)
	@read -p "Type destroy-prod to destroy the environment: " c && [ "$$c" = "destroy-prod" ]
	cd terraform/envs/prod && terraform destroy

outputs: ## Show app URL, dashboard URL...
	cd terraform/envs/prod && terraform output

verify-clean: ## After destroy: list anything that still bills in the region
	@echo "NAT gateways:";   aws ec2 describe-nat-gateways --region $(REGION) --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
	@echo "Elastic IPs:";    aws ec2 describe-addresses --region $(REGION) --query 'Addresses[].PublicIp' --output text
	@echo "Load balancers:"; aws elbv2 describe-load-balancers --region $(REGION) --query 'LoadBalancers[].LoadBalancerName' --output text
	@echo "RDS:";            aws rds describe-db-instances --region $(REGION) --query 'DBInstances[].DBInstanceIdentifier' --output text
	@echo "ElastiCache:";    aws elasticache describe-replication-groups --region $(REGION) --query 'ReplicationGroups[].ReplicationGroupId' --output text
	@echo "ECS clusters:";   aws ecs list-clusters --region $(REGION) --query 'clusterArns' --output text
	@echo "WAF ACLs:";       aws wafv2 list-web-acls --scope REGIONAL --region $(REGION) --query 'WebACLs[].Name' --output text
	@echo "CloudFront:";     aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text
	@echo "(empty lines = nothing billing)"

load: ## Generate traffic against the deployed app for the dashboard (URL=https://xxx.cloudfront.net)
	.venv/bin/python scripts/load.py $(URL)
