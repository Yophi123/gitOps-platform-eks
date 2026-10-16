variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (also Cilium's cluster.name, used for ENI garbage-collection tags)"
}

variable "k8s_service_host" {
  type        = string
  description = "API server host without scheme (module.eks.cluster_endpoint_host). Required with kube-proxy replacement."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR, used as ipv4NativeRoutingCIDR"
}

variable "chart_version" {
  type        = string
  description = "Cilium Helm chart version (no leading v)"
  default     = "1.20.2"
}

variable "enable_prefix_delegation" {
  type        = bool
  description = "Assign /28 prefixes to ENIs instead of single IPs. Raises pods per node; Karpenter max-pods must match."
  default     = false
}

variable "hubble_ui_enabled" {
  type        = bool
  description = "Deploy the Hubble UI"
  default     = true
}

variable "operator_replicas" {
  type        = number
  description = "Cilium operator replicas. Replicas never share a node, so keep this <= the number of system nodes (2 is enough for HA)."
  default     = 2

  validation {
    condition     = var.operator_replicas >= 1 && var.operator_replicas <= 2
    error_message = "operator_replicas must be 1 or 2."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto AWS resources created by this module."
  default     = {}
}