variable "name" {
  description = "Name prefix, e.g. ticketrush-prod."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. /16 gives 65k addresses; we carve /20 subnets (4091 usable each)."
  type        = string
  default     = "10.0.0.0/16"
  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "Must be a valid CIDR."
  }
}

variable "az_count" {
  description = "Number of AZs (2 = high availability at lowest cost)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use 2 or 3 AZs."
  }
}

variable "nat_per_az" {
  description = "true = one NAT per AZ (resilient, ~2x cost). false = a single shared NAT."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention of VPC flow logs in CloudWatch."
  type        = number
  default     = 7
}

variable "permissions_boundary_arn" {
  description = "Boundary attached to the flow-logs IAM role."
  type        = string
}
