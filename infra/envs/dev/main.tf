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

  project_name = var.project_name
  cluster_name = local.cluster_name

  kubernetes_version = var.kubernetes_version

  control_plane_subnet_ids = module.vpc.infra_subnet_ids
  node_subnet_ids          = module.vpc.infra_subnet_ids

  endpoint_public_access = true
  public_access_cidrs    = var.admin_cidrs
  admin_principal_arns   = var.admin_principal_arns

  system_node_instance_types = var.system_node_instance_types
  system_node_desired_size   = var.system_node_desired_size
  system_node_dedicated      = true
}
