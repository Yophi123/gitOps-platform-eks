locals {
  cluster_name = "gitops-eks-dev"
}

module "vpc" {
  source = "../../modules/vpc"

  project_name = var.project_name
  cluster_name = local.cluster_name

  enable_s3_endpoint = true
  ipv6_enabled       = false
}

module "eks" {
  source = "../../modules/eks"

  project_name       = var.project_name
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  control_plane_subnet_ids = module.vpc.infra_subnet_ids
  node_subnet_ids          = module.vpc.infra_subnet_ids

  endpoint_public_access = true
  public_access_cidrs    = var.admin_cidrs
  admin_principal_arns   = var.admin_principal_arns

  system_node_instance_types = var.system_node_instance_types
  system_node_desired_size   = var.system_node_desired_size
  system_node_dedicated      = true

  # Nodes are created after Cilium, so they come up Ready. Wait for NAT Gateway as well
  node_group_wait_for = [module.cilium_bootstrap.release_name, module.vpc.nat_gateway_id]

  depends_on = [ module.vpc ]
}

## Cilium: ENI IPAM, kube-proxy replacement, Hubble (nodes become Ready)
module "cilium_bootstrap" {
  source = "../../modules/cilium-bootstrap"

  project_name      = var.project_name
  cluster_name      = module.eks.cluster_name
  k8s_service_host  = module.eks.cluster_endpoint_host
  vpc_cidr          = module.vpc.vpc_cidr
  chart_version     = var.cilium_version
  operator_replicas = min(2, var.system_node_desired_size)
}


## CoreDNS: after the node group is ACTIVE (nodes Ready)
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks]
}


## Karpenter: AWS resources + controller (NodePools live in gitops/)
module "karpenter" {
  source = "../../modules/karpenter"

  project_name  = var.project_name
  cluster_name  = module.eks.cluster_name
  chart_version = var.karpenter_version
  replicas      = min(2, var.system_node_desired_size)

  depends_on = [aws_eks_addon.coredns] # controller needs cluster DNS
}

## Argo CD + root app: from here on, Git is the source of truth in-cluster
module "argocd_bootstrap" {
  source = "../../modules/argocd-bootstrap"

  environment               = "dev"
  repo_url                  = var.gitops_repo_url
  argocd_chart_version      = var.argocd_chart_version
  argocd_apps_chart_version = var.argocd_apps_chart_version

  depends_on = [module.karpenter]
}

## Vault: 3-node Raft cluster behind an internal NLB
module "vault" {
  source = "../../modules/vault-cluster"

  project_name = var.project_name
  name         = "${local.cluster_name}-vault"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.infra_subnet_ids

  client_security_groups = {
    eks = module.eks.cluster_security_group_id
  }
}

## Postgres for dynamic credentials (Vault creates per-lease users)
module "rds" {
  source = "../../modules/rds"

  project_name = var.project_name
  name         = "${local.cluster_name}-app"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.db_subnet_ids

  allowed_security_groups = {
    vault = module.vault.security_group_id
    eks   = module.eks.cluster_security_group_id
  }
}