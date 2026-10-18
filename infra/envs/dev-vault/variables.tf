variable "region" {
  type = string
}

variable "project_name" {
  type    = string
  default = "gitops-eks"
}

variable "environment" {
  type = string
}

variable "state_bucket" {
  type        = string
  description = "Bucket holding the platform root's state"
}

variable "platform_state_key" {
  type        = string
  description = "State key of the platform root (envs/<env>)"
}

variable "vault_addr" {
  type        = string
  description = "Vault address as seen from this machine (SSM tunnel)"
  default     = "https://localhost:8200"
}

variable "workloads" {
  type = map(object({
    namespace       = string
    service_account = string
    db_default_ttl  = optional(number, 3600)
    db_max_ttl      = optional(number, 86400)
  }))
  description = "Workloads that get Vault identity and dynamic DB credentials"
}