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

  # Nodes are created after Cilium, so they come up Ready
  node_group_wait_for = [module.cilium_bootstrap.release_name]
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
