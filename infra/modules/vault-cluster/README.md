# vault-cluster

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-Raft%20x3-FFEC6E?logo=vault&logoColor=black)
![Unseal](https://img.shields.io/badge/unseal-AWS%20KMS-FF9900)
![TLS](https://img.shields.io/badge/TLS-private%20CA-informational)

Three-node Vault cluster (integrated Raft storage) in an ASG behind an internal
NLB, with KMS auto-unseal and Raft auto-join by EC2 tag.

## Design

- **Auto-join** via `retry_join { auto_join = "provider=aws tag_key=vault-cluster ..." }`.
  Initialize one node and the rest join and unseal themselves. ASG
  replacements rejoin the same way.
- **TLS**: a Terraform-managed CA and server cert. SANs cover the NLB DNS name,
  `vault.internal` (Raft peer verification), `localhost` and `127.0.0.1`. Nodes
  read the cert and key from SSM Parameter Store at boot. The key is not in user
  data, but it is in Terraform state.
- **NLB** with its own SG (8200 from client SGs); nodes accept 8200 only from the
  NLB and their peers. Health checks count standbys as healthy, since they
  forward to the active node.
- **ASG uses EC2 health checks**, because uninitialized nodes fail the NLB check.
- **Instance role**: KMS (unseal key only), `ec2:DescribeInstances` (auto-join),
  SSM parameters under `/<name>/tls/*`, and SSM Session Manager.

## Usage

```hcl
module "vault" {
  source = "../../modules/vault-cluster"

  project_name              = var.project_name
  name                      = "${local.cluster_name}-vault"
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.infra_subnet_ids
  client_security_group_ids = [module.eks.cluster_security_group_id]
}
```

Build the AMI first (`packer/vault`).

## Outputs

| Name | Description |
|------|-------------|
| vault_addr | `https://<nlb>:8200` for in-VPC clients |
| nlb_dns_name | Internal NLB DNS name |
| ca_cert_pem | CA certificate for clients |
| security_group_id | Node SG (allow into RDS) |
| asg_name | ASG name |
| kms_key_arn | Unseal key ARN |
| cluster_tag | Tag used to find the nodes |