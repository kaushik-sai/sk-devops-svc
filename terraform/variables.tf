variable "env" {
  description = "Environment to deploy: dev or prod."
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
  description = "Container image for the app."
  type        = string
  # Placeholder only: a public sample image so plan has a value. There is no
  # registry in this project; a real deploy passes <registry>/sk-svc:<commit SHA>.
  default = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "min_replicas" {
  description = "Minimum number of running replicas."
  type        = number
}

variable "max_replicas" {
  description = "Maximum number of running replicas."
  type        = number
}

variable "fail_rate" {
  description = "Value of the app's FAIL_RATE env var."
  type        = string
  default     = "0"
}

variable "purge_protection_enabled" {
  description = "Key Vault purge protection (on for prod, off for dev)."
  type        = bool
}

variable "db_password" {
  description = "Database password to store in Key Vault. No default and never in tfvars: pass it with TF_VAR_db_password."
  type        = string
  sensitive   = true
}
