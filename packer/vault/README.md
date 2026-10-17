# packer/vault

![Packer](https://img.shields.io/badge/Packer-AMI-02A8EF?logo=packer&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-Community-FFEC6E?logo=vault&logoColor=black)
![OS](https://img.shields.io/badge/OS-Amazon%20Linux%202023-FF9900)

Amazon Linux 2023 AMI with Vault installed from the HashiCorp repo. No config,
certificates or data are baked in; the `vault-cluster` module's user data
writes them at boot.

```bash
cd packer/vault
packer init .
packer build -var region=ap-southeast-1 -var vault_version=<x.y.z> .
```

Without a default VPC, pass a public subnet: `-var subnet_id=subnet-...`
(for example one of the VPC's web subnets).

The `vault-cluster` module picks the newest AMI tagged `Component=vault` and
`Project=<project_name>`.