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

output "vault_addr" {
  description = "Vault address for in-VPC clients"
  value       = module.vault.vault_addr
}

output "vault_ca_cert_pem" {
  description = "Vault CA certificate"
  value       = module.vault.ca_cert_pem
}

output "vault_cluster_tag" {
  description = "Tag on every Vault node"
  value       = module.vault.cluster_tag
}

output "eks_oidc_issuer_url" {
  description = "EKS OIDC issuer (Vault JWT auth)"
  value       = module.eks.oidc_issuer_url
}

output "rds_address" {
  value = module.rds.address
}

output "rds_port" {
  value = module.rds.port
}

output "rds_db_name" {
  value = module.rds.db_name
}

output "rds_master_secret_arn" {
  value = module.rds.master_secret_arn
}


output "cilium_helm_values" {
  description = "Rendered Cilium values (gitops/envs/<env>/values/cilium.yaml)"
  value       = module.cilium_bootstrap.helm_values
}

output "karpenter_helm_values" {
  description = "Rendered Karpenter values (gitops/envs/<env>/values/karpenter.yaml)"
  value       = module.karpenter.helm_values
}
