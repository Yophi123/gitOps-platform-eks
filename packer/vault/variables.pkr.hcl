variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "project_name" {
  type        = string
  description = "Tagged on the AMI; the vault-cluster module filters on it"
  default     = "gitops-eks"
}

variable "vault_version" {
  type        = string
  description = "Vault version to pin, e.g. 1.21.1 (empty = latest in the HashiCorp apt repo)"
  default     = "2.2.0"
}