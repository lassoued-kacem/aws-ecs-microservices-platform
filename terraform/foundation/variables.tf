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

variable "github_oidc_sub_prefix" {
  description = "Immutable OIDC subject prefix, if the repo uses it (gh api repos/OWNER/REPO/actions/oidc/customization/sub -> sub_claim_prefix), e.g. repo:owner@123/repo@456. Empty = classic subjects only."
  type        = string
  default     = ""
  validation {
    condition     = var.github_oidc_sub_prefix == "" || can(regex("^repo:[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", var.github_oidc_sub_prefix))
    error_message = "Must look like repo:owner@<id>/repo@<id>, or be empty."
  }
}
