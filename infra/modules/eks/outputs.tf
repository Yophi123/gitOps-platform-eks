output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "API server endpoint (https URL)"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_endpoint_host" {
  description = "API server host without scheme: Cilium's k8sServiceHost (needed with kube-proxy replacement)"
  value       = trimprefix(aws_eks_cluster.this.endpoint, "https://")
}

output "cluster_ca_data" {
  description = "Base64 cluster CA certificate"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster SG (shared by control plane, system nodes and Karpenter nodes)"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer (for Vault's JWT/Kubernetes auth)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "service_ipv4_cidr" {
  description = "Kubernetes Service CIDR"
  value       = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
}

output "system_node_role_arn" {
  description = "IAM role ARN of the system node group"
  value       = aws_iam_role.system_node.arn
}

output "system_node_group_name" {
  description = "System managed node group name"
  value       = aws_eks_node_group.system.node_group_name
}

output "kms_key_arn" {
  description = "KMS key ARN used for secrets encryption"
  value       = aws_kms_key.eks.arn
}