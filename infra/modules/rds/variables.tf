variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "name" {
  type        = string
  description = "Instance identifier, e.g. gitops-eks-dev-app"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Isolated database subnets"
}

variable "allowed_security_groups" {
  type        = map(string)
  description = "SGs allowed on 5432, keyed by a static label (e.g. { vault = sg-..., eks = sg-... })"
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL major version"
  default     = "18"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type        = string
  description = "Master user. Vault uses it to create dynamic users, then rotates its password."
  default     = "vault_admin"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
