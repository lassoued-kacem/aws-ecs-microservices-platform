variable "region" {
  description = "AWS region for the state bucket and budget."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Short project name used as a prefix for every resource."
  type        = string
  default     = "ticketrush"
}

variable "alert_email" {
  description = "Email that receives budget alerts. Pass via TF_VAR_alert_email, never commit it."
  type        = string
  sensitive   = true
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget. Budgets ALERT, they do not stop spending."
  type        = number
  default     = 60
}
