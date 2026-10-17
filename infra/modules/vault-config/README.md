# vault-config

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-config%20as%20code-FFEC6E?logo=vault&logoColor=black)
![Auth](https://img.shields.io/badge/auth-JWT%20(EKS%20OIDC)-326CE5?logo=kubernetes&logoColor=white)
![Secrets](https://img.shields.io/badge/secrets-dynamic%20Postgres-4169E1?logo=postgresql&logoColor=white)

Vault's own configuration: auth, secrets engines, policies and Raft autopilot.
Applied from `infra/envs/<env>-vault` through an SSM port-forward.

## Design

- **JWT auth with the EKS OIDC issuer.** Vault fetches the cluster's public JWKS;
  no Kubernetes API access and no long-lived token reviewer JWT.
- **Per-workload identity.** Each workload's Vault role is bound to its own
  service account (`bound_subject`) and token audience `vault`.
- **Dynamic Postgres users.** Each lease creates a user with an expiry. On
  revocation, owned objects are reassigned to the master user, then the user is
  dropped.
- **Root rotation.** The RDS master password is read once from Secrets Manager
  and rotated by Vault. The connection ignores later changes, since Terraform
  no longer knows the password.
- **Autopilot** removes dead Raft peers (never below `min_quorum`).

## Usage

```hcl
module "vault_config" {
  source = "../../modules/vault-config"

  eks_oidc_issuer_url   = data.terraform_remote_state.platform.outputs.eks_oidc_issuer_url
  rds_master_secret_arn = data.terraform_remote_state.platform.outputs.rds_master_secret_arn

  workloads = {
    demo = { namespace = "demo", service_account = "demo-app" }
  }
}
```

**Recreating the connection after rotation fails** because the stored password
is stale. Reset the RDS master password in AWS, update the Secrets Manager
secret, then `terraform apply -replace=module.vault_config.vault_database_secret_backend_connection.app`.

## Outputs

| Name | Description |
|------|-------------|
| jwt_auth_path | JWT auth mount path |
| database_mount_path | Database engine path |
| kv_mount_path | KV v2 path |
| workload_roles | Per-workload JWT role, creds path, bound subject |