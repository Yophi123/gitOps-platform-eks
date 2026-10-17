variable "region" {
  type        = string
  description = "AWS region for the whole stack."
  default     = "ap-southeast-1"
}

variable "project_name" {
  type        = string
  description = "Project name, used as a prefix for resource names"
  default     = "gitops-eks"
}

variable "repository" {
  type        = string
  description = "Git repository that manages this stack (for tagging)"
}

## Network
variable "vpc_cidr" {
  type        = string
  description = "VPC /16. Keep dev and prod non-overlapping."
}

## EKS
variable "kubernetes_version" {
  type        = string
  description = "Kubernetes minor version in standard support"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public EKS API endpoint"

  # validation {
  #   condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
  #   error_message = "Don't open the API endpoint to the internet; list specific CIDRs."
  # }
}

variable "admin_principal_arns" {
  type        = list(string)
  description = "Extra IAM principals granted cluster-admin (not the Terraform identity)"
  default     = []
}

variable "system_node_instance_types" {
  type        = list(string)
  description = "Instance types for the system node group"
  default     = ["t3.medium"]
}

variable "system_node_desired_size" {
  type        = number
  description = "Initial number of system nodes"
  default     = 3
}

# Cilium
variable "cilium_version" {
  type        = string
  description = "Cilium Helm chart version"
  default     = "1.20.2"
}

variable "karpenter_version" {
  type        = string
  description = "Karpenter chart version"
  default     = "1.15.0"
}