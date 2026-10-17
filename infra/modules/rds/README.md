# rds

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)
![Access](https://img.shields.io/badge/access-Vault%20dynamic%20creds-FFEC6E?logo=vault&logoColor=black)

Private PostgreSQL instance in the isolated database subnets. Workloads never
get static credentials: Vault's database secrets engine creates short-lived
users.

## Design

- **Master password** is random and written once to Secrets Manager. Stage 4b
  hands it to Vault, which rotates it, so afterwards only Vault knows it.
  Terraform ignores password drift.
- **5432 open only** to the listed SGs (Vault nodes, EKS cluster SG).
- Encrypted gp3 storage, not publicly accessible, single-AZ for dev.

## Usage

```hcl
module "rds" {
  source = "../../modules/rds"

  project_name               = var.project_name
  name                       = "${local.cluster_name}-app"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.db_subnet_ids
  allowed_security_group_ids = [module.vault.security_group_id, module.eks.cluster_security_group_id]
}
```

## Outputs

| Name | Description |
|------|-------------|
| address | RDS hostname |
| port | RDS port |
| db_name | Application database |
| master_secret_arn | Initial master credentials (Secrets Manager) |
| security_group_id | Database SG |