module "vault_config" {
  source = "../../modules/vault-config"

  eks_oidc_issuer_url   = data.terraform_remote_state.platform.outputs.eks_oidc_issuer_url
  rds_master_secret_arn = data.terraform_remote_state.platform.outputs.rds_master_secret_arn

  workloads = var.workloads
}