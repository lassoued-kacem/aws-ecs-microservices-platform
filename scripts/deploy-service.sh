#!/usr/bin/env bash
# Render + register + deploy one ECS service with a new image tag.
#
# The pipeline owns task-definition REVISIONS; Terraform owns the SKELETON.
# We start from the latest revision of the family (which includes any change
# Terraform made: env vars, secrets, CPU...), swap only the app image, register
# it as a new revision and roll the service. ECS's circuit breaker rolls back
# automatically if the new tasks never become healthy.
#
# usage: deploy-service.sh <cluster> <service> <family> <image-uri>
set -euo pipefail
CLUSTER="$1" SERVICE="$2" FAMILY="$3" IMAGE="$4"

echo "::group::Render task definition for ${SERVICE}"
aws ecs describe-task-definition --task-definition "$FAMILY" --query taskDefinition --output json > current-td.json
jq --arg IMG "$IMAGE" '
  .containerDefinitions |= map(if .name == "app" then .image = $IMG else . end)
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
        .registeredAt, .registeredBy, .deregisteredAt)
' current-td.json > new-td.json
echo "::endgroup::"

NEW_ARN=$(aws ecs register-task-definition --cli-input-json file://new-td.json --query taskDefinition.taskDefinitionArn --output text)
echo "Registered ${NEW_ARN}"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW_ARN" --query service.deployments[0].id --output text

echo "Waiting for ${SERVICE} to become stable (circuit breaker rolls back on failure)..."
if ! aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"; then
  echo "::error::${SERVICE} did not stabilise"; exit 1
fi

# If the circuit breaker rolled back, the primary deployment is NOT our revision.
RUNNING=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)
if [[ "$RUNNING" != "$NEW_ARN" ]]; then
  echo "::error::Deployment of ${SERVICE} was rolled back by the ECS circuit breaker (running ${RUNNING})"
  exit 1
fi
echo "${SERVICE} is running ${NEW_ARN}"
