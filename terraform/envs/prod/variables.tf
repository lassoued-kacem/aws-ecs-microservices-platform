variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "project" {
  type    = string
  default = "ticketrush"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "alert_email" {
  description = "Receives CloudWatch alarm emails. Supplied via TF_VAR_alert_email / the ALERT_EMAIL GitHub variable."
  type        = string
  sensitive   = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "nat_per_az" {
  type    = bool
  default = false
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Standby replica in a second AZ with automatic failover (~2x DB cost)."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "true = destroy without a final snapshot (environment is rebuilt from migrations + seed)."
  type        = bool
  default     = true
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "cache_replicas" {
  description = "0 = single node (cheapest). 1 = primary + replica in another AZ with automatic failover."
  type        = number
  default     = 0
}

variable "service_desired_count" {
  type    = number
  default = 2
}

variable "service_max_count" {
  type    = number
  default = 4
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "waf_rate_limit_per_5min" {
  description = "Max requests per client IP per 5 minutes before WAF blocks."
  type        = number
  default     = 2000
}

# SLO hooks (the SLOs themselves are added later).
variable "slo_availability_target" {
  type    = number
  default = 99.5
}

variable "slo_latency_p99_ms" {
  type    = number
  default = 800
}
