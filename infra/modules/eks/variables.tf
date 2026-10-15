variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (must match the karpenter.sh/discovery tag on the VPC's app subnets)"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes minor version, e.g. \"1.34\". Pick one in standard support: aws eks describe-cluster-versions"
}

variable "support_type" {
  type        = string
  description = "STANDARD auto-upgrades at end of standard support; EXTENDED keeps the version at 6x the control-plane price."
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.support_type)
    error_message = "support_type must be STANDARD or EXTENDED."
  }
}

variable "control_plane_subnet_ids" {
  type        = list(string)
  description = "Subnets for the control-plane ENIs (infra tier). At least two AZs."

  validation {
    condition     = length(var.control_plane_subnet_ids) >= 2
    error_message = "EKS needs control-plane subnets in at least two AZs."
  }
}

variable "node_subnet_ids" {
  type        = list(string)
  description = "Subnets for the system managed node group (infra tier)"
}

variable "service_ipv4_cidr" {
  type        = string
  description = "Kubernetes Service CIDR. Must not overlap the VPC or any peered network."
  default     = "172.20.0.0/16"
}

variable "endpoint_public_access" {
  type        = bool
  description = "Expose the API server publicly (restricted by public_access_cidrs). Private access is always on."
  default     = true
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public API endpoint. Narrow this to your IP; GitHub-hosted runners need it open or a self-hosted runner in the VPC."
  default     = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  type        = list(string)
  description = "Control-plane log types sent to CloudWatch"
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  type        = number
  description = "Retention for the control-plane log group"
  default     = 30
}

variable "admin_principal_arns" {
  type        = list(string)
  description = "IAM role/user ARNs granted cluster-admin via access entries. Do NOT include the identity running Terraform (it is added automatically)."
  default     = []
}

variable "system_node_instance_types" {
  type        = list(string)
  description = "Instance types for the system node group (Cilium operator, Karpenter, CoreDNS, Argo CD)"
  default     = ["t3.small"]
}

variable "system_node_ami_type" {
  type        = string
  description = "Managed node group AMI type"
  default     = "AL2023_x86_64_STANDARD"
}

variable "system_node_capacity_type" {
  type        = string
  description = "ON_DEMAND or SPOT. Keep ON_DEMAND: Karpenter itself runs here."
  default     = "ON_DEMAND"
}

variable "system_node_min_size" {
  type    = number
  default = 1
}

variable "system_node_max_size" {
  type    = number
  default = 3
}

variable "system_node_desired_size" {
  type    = number
  default = 1
}

variable "system_node_disk_size" {
  type        = number
  description = "Root volume size (GiB) for system nodes"
  default     = 30
}

variable "system_node_dedicated" {
  type        = bool
  description = "Taint system nodes with CriticalAddonsOnly so app pods land on Karpenter nodes"
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto all resources created by this module."
  default     = {}
}