## Platform outputs (EKS issuer, RDS) from the envs/<env> state
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.platform_state_key
    region = var.region
  }
}


module "vault_config" {
  source = "../../modules/vault-config"

  eks_oidc_issuer_url   = data.terraform_remote_state.platform.outputs.eks_oidc_issuer_url
  rds_master_secret_arn = data.terraform_remote_state.platform.outputs.rds_master_secret_arn

  workloads = var.workloads
}