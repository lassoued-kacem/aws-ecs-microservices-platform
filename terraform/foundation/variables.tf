variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Project prefix."
  type        = string
  default     = "ticketrush"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI roles, as owner/name (e.g. octocat/ticketrush)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Use the form owner/repo."
  }
}

variable "state_bucket" {
  description = "Name of the Terraform state bucket created by the bootstrap layer."
  type        = string
}

variable "services" {
  description = "Container services that get an ECR repository and a deploy pointer."
  type        = set(string)
  default     = ["identity", "ticketing"]
}

variable "create_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider (only one per account is allowed)."
  type        = bool
  default     = true
}
