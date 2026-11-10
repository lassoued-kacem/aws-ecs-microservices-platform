output "service_name" {
  value = aws_ecs_service.this.name
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.this.arn_suffix
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "task_family" {
  value = aws_ecs_task_definition.this.family
}
