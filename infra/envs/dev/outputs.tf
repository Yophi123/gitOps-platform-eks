output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC ID"
  value       = module.vpc.vpc_cidr
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command to add this cluster to your kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "cilium_chart_version" {
  description = "Installed Cilium chart version"
  value       = module.cilium_bootstrap.chart_version
}

output "karpenter_node_role_name" {
  description = "Node role for EC2NodeClass spec.role"
  value       = module.karpenter.node_role_name
}

output "argocd_admin_password_command" {
  description = "Read the initial Argo CD admin password"
  value       = module.argocd_bootstrap.admin_password_command
}