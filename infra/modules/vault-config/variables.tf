variable "eks_oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL (Vault JWT auth discovers the JWKS from it)"
}

variable "jwt_auth_path" {
  type        = string
  description = "Mount path of the JWT auth method"
  default     = "jwt-eks"
}

variable "token_audience" {
  type        = string
  description = "Audience workloads request on their service-account tokens"
  default     = "vault"
}

variable "rds_master_secret_arn" {
  type        = string
  description = "Secrets Manager ARN with the initial RDS master credentials"
}

variable "rotate_root_credentials" {
  type        = bool
  description = "Rotate the RDS master password inside Vault right after configuring the connection"
  default     = true
}

variable "workloads" {
  type = map(object({
    namespace       = string
    service_account = string
    db_default_ttl  = optional(number, 3600)  # 1h
    db_max_ttl      = optional(number, 86400) # 24h
  }))
  description = "Workloads that get a Vault login role and dynamic DB credentials, keyed by name"
}

variable "autopilot_min_quorum" {
  type        = number
  description = "Minimum voters; autopilot never removes dead servers below this"
  default     = 3
}