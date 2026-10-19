variable "env" {
  description = "Environment name, used in every resource name (<type>-sk-svc-<env>)."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be \"dev\" or \"prod\"."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "southindia"
}

variable "image" {
  description = "Container image the app runs. Real deploys pass <registry>/sk-svc:<40-char commit SHA>."
  type        = string
}

variable "min_replicas" {
  description = "Minimum number of running replicas of the app."
  type        = number

  validation {
    condition     = var.min_replicas >= 1
    error_message = "min_replicas must be at least 1 (no scale to zero for this service)."
  }
}

variable "max_replicas" {
  description = "Maximum number of running replicas of the app (keep it >= min_replicas)."
  type        = number

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 10
    error_message = "max_replicas must be between 1 and 10."
  }

  # Cross-variable validation needs Terraform 1.9 or later (required_version below).
  validation {
    condition     = var.max_replicas >= var.min_replicas
    error_message = "max_replicas must be at least min_replicas."
  }
}

variable "fail_rate" {
  description = "Value of the FAIL_RATE env var (share of requests the demo app fails on purpose)."
  type        = string
  default     = "0"
}

variable "purge_protection_enabled" {
  description = "Key Vault purge protection. Once enabled on a real vault it cannot be turned off."
  type        = bool
}

variable "db_password" {
  description = "Database password stored in Key Vault. Supplied at plan/apply time only, never in tfvars."
  type        = string
  sensitive   = true
}
