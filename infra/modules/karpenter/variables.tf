variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (also the interruption queue name and discovery tag value)"
}

variable "chart_version" {
  type        = string
  description = "Karpenter chart version, used for both karpenter-crd and karpenter"
  default     = "1.15.0"
}

variable "replicas" {
  type        = number
  description = "Controller replicas. Replicas never share a node, so keep this <= the number of system nodes."
  default     = 2

  validation {
    condition     = var.replicas >= 1 && var.replicas <= 2
    error_message = "replicas must be 1 or 2."
  }
}

variable "create_spot_service_linked_role" {
  type        = bool
  description = "Create AWSServiceRoleForEC2Spot. Leave false if the account has used Spot before (it already exists)."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto AWS resources created by this module."
  default     = {}
}