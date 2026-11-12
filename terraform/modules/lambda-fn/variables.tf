variable "name" {
  description = "Full function name."
  type        = string
}

variable "source_dir" {
  description = "Directory with handler.py (stdlib + runtime boto3 only)."
  type        = string
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "timeout" {
  type    = number
  default = 10
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "attach_policy" {
  description = "Attach policy_json. A separate static flag because count cannot depend on a policy that is only known after apply."
  type        = bool
  default     = false
}

variable "policy_json" {
  description = "Least-privilege permissions for this function. null = logs only."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}
