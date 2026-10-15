variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name, used for the karpenter.sh/discovery tag on app subnets"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (must be a /16 for the 3 AZ x 5 tier /20 layout)"
  default     = "10.16.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR block."
  }
}

variable "enable_private_zone" {
  type        = bool
  description = "Create a Route 53 private hosted zone. Not needed for EKS (CoreDNS handles discovery)."
  default     = false
}

variable "private_zone_name" {
  type        = string
  description = <<-EOT
    Fully qualified private zone name. Only used when enable_private_zone = true.
    Avoid .local (mDNS collisions).
  EOT
  default     = null

  validation {
    condition     = var.private_zone_name == null || length(split(".", trimsuffix(coalesce(var.private_zone_name, "x"), "."))) >= 2
    error_message = "private_zone_name must be fully qualified, e.g. gitops-eks.internal (not a single label)."
  }

  validation {
    condition     = var.private_zone_name == null || !endswith(trimsuffix(coalesce(var.private_zone_name, "x"), "."), ".local")
    error_message = "Do not use the .local TLD; it collides with mDNS resolvers."
  }
}

variable "records" {
  type = map(object({
    name    = string
    type    = optional(string, "A")
    ttl     = optional(number, 60)
    records = optional(list(string))
    alias = optional(object({
      dns_name               = string
      zone_id                = string
      evaluate_target_health = optional(bool, true)
    }))
  }))
  description = <<-EOT
    Private zone records keyed by an arbitrary label. "name" is relative to the
    zone; use "" for the apex. Set either "alias" or "records" + "ttl", never both.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for r in var.records : (r.alias != null) != (r.records != null)
    ])
    error_message = "Each record must set exactly one of `alias` or `records`."
  }
}

variable "records_force_destroy" {
  type        = bool
  description = "Delete all records when destroying the zone."
  default     = false
}

variable "enable_dns_hostnames" {
  type    = bool
  default = true
}

variable "enable_dns_support" {
  type    = bool
  default = true
}

variable "enable_dhcp_options" {
  type        = bool
  description = "Add the private zone to the DHCP search path. Off for EKS: pods inherit it and amplify DNS lookups."
  default     = false
}

variable "map_public_ip_on_launch" {
  type        = bool
  description = "Auto-assign public IPv4 addresses in the web tier. Off: only load balancers belong there."
  default     = false
}

variable "ipv6_enabled" {
  type        = bool
  description = "Assign an Amazon-provided IPv6 /56 to the VPC and a /64 to every subnet."
  default     = false
}

variable "enable_s3_endpoint" {
  type        = bool
  description = "Create a free S3 gateway endpoint on the private and database route tables."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto all resources created by this module."
  default     = {}
}