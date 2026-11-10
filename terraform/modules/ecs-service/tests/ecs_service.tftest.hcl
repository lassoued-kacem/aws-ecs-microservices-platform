mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-3" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-3:123456789012:targetgroup/mock/abc" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:eu-west-3:123456789012:task-definition/mock:1" }
  }
}

variables {
  name                       = "identity"
  name_prefix                = "test"
  cluster_arn                = "arn:aws:ecs:eu-west-3:123456789012:cluster/test"
  cluster_name               = "test"
  vpc_id                     = "vpc-123"
  subnet_ids                 = ["subnet-a", "subnet-b"]
  image                      = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/x/identity:abc123"
  alb_listener_arn           = "arn:aws:elasticloadbalancing:eu-west-3:123456789012:listener/app/x/y/z"
  alb_security_group_id      = "sg-alb"
  path_patterns              = ["/api/auth/*"]
  listener_priority          = 10
  origin_verify_header_value = "secret"
  permissions_boundary_arn   = "arn:aws:iam::123456789012:policy/boundary"
  secrets                    = { DB_PASSWORD = "arn:aws:ssm:eu-west-3:123456789012:parameter/x" }
}

run "safe_deployments" {
  command = plan
  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable && aws_ecs_service.this.deployment_circuit_breaker[0].rollback
    error_message = "Circuit breaker with automatic rollback must be enabled."
  }
  assert {
    condition     = aws_ecs_service.this.deployment_minimum_healthy_percent == 100
    error_message = "Deploys must never reduce healthy capacity."
  }
  assert {
    condition     = one(aws_ecs_service.this.network_configuration).assign_public_ip == false
    error_message = "Tasks must not get public IPs."
  }
}

run "hardened_container" {
  command = plan
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "App container must have a read-only root filesystem."
  }
  assert {
    condition     = aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "Tasks run on Graviton."
  }
  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets) == 1
    error_message = "Secrets must be injected through the secrets field."
  }
}

run "roles_carry_boundary" {
  command = plan
  assert {
    condition     = aws_iam_role.task.permissions_boundary == var.permissions_boundary_arn && aws_iam_role.execution.permissions_boundary == var.permissions_boundary_arn
    error_message = "Every role must carry the permissions boundary."
  }
}

run "refuses_placeholder_image" {
  command = plan
  variables {
    image = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/x/identity:none"
  }
  expect_failures = [aws_ecs_task_definition.this]
}
