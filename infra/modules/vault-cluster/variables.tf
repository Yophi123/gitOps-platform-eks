variable "project_name" {
  type        = string
  description = "Project name; also used to find the Packer AMI (tag Project)"
}

variable "name" {
  type        = string
  description = "Cluster name, e.g. gitops-eks-dev-vault. Used for resource names and the auto-join tag."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnets for the nodes and the internal NLB (one per AZ)"
}

variable "client_security_groups" {
  type        = map(string)
  description = "SGs allowed to reach Vault on 8200, keyed by a static label (e.g. { eks = sg-... })"
}

variable "node_count" {
  type        = number
  description = "Raft voters. Use an odd number."
  default     = 3

  validation {
    condition     = var.node_count % 2 == 1
    error_message = "node_count must be odd (Raft quorum)."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "ami_id" {
  type        = string
  description = "Override the AMI. Empty = newest AMI tagged Component=vault, Project=<project_name>."
  default     = ""
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto all resources."
  default     = {}
}