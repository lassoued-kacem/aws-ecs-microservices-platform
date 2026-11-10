variable "name" {
  description = "Service name, e.g. identity."
  type        = string
}

variable "name_prefix" {
  description = "Environment prefix, e.g. ticketrush-prod."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private app subnets (no public IPs)."
  type        = list(string)
}

variable "image" {
  description = "Full image URI including the immutable SHA tag."
  type        = string
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "environment" {
  description = "Plain (non-secret) environment variables."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env var name -> SSM parameter ARN. Resolved by ECS at task start."
  type        = map(string)
  default     = {}
}

variable "alb_listener_arn" {
  type = string
}

variable "alb_security_group_id" {
  type = string
}

variable "path_patterns" {
  description = "ALB path patterns routed to this service."
  type        = list(string)
}

variable "listener_priority" {
  description = "Lower = evaluated first. More specific paths need lower numbers."
  type        = number
}

variable "origin_verify_header_value" {
  description = "Secret header CloudFront adds; requests without it never reach the service."
  type        = string
  sensitive   = true
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 4
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "task_role_policy_json" {
  description = "Extra least-privilege permissions for the app (e.g. SQS send). null = none."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  type = string
}

variable "adot_image" {
  description = "AWS Distro for OpenTelemetry collector image (pinned)."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.51.0"
}

variable "health_check_grace_seconds" {
  description = "Time ECS ignores ALB health checks after start (migrations run at boot)."
  type        = number
  default     = 60
}
