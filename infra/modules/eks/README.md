# eks

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![AWS Provider](https://img.shields.io/badge/AWS%20provider-%3E%3D%206.0-FF9900)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![CNI](https://img.shields.io/badge/CNI-Cilium%20(ENI%20mode)-F8C517)
![Auth](https://img.shields.io/badge/auth-access%20entries-informational)
![infra-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/infra-ci.yml/badge.svg)

EKS control plane plus a small, tainted system node group, built for Cilium
(ENI mode, kube-proxy replacement) and Karpenter.

## Design

- **No default addons** (`bootstrap_self_managed_addons = false`): no aws-node,
  kube-proxy or CoreDNS. Nodes stay NotReady until Cilium is installed.
- **Access entries only** (`authentication_mode = "API"`): no aws-auth ConfigMap.
  The identity running Terraform gets admin automatically.
- **Secrets** are envelope-encrypted with a dedicated, rotating KMS key.
- **System nodes** use IMDSv2 with hop limit 1 and encrypted gp3 volumes. They
  carry the `node.cilium.io/agent-not-ready` startup taint, plus an optional
  `CriticalAddonsOnly` taint.
- **No CNI policy on the node role.** The Cilium operator gets ENI permissions
  through Pod Identity instead.
- **Karpenter discovery.** The cluster SG is tagged `karpenter.sh/discovery`, so
  Karpenter nodes share it.
- **Pod Identity agent** is installed here because it runs on the host network
  before any CNI exists. CoreDNS and EBS CSI are added in the root, after Cilium.
- **`upgrade_policy = STANDARD`** keeps forgotten clusters out of extended-support
  pricing.

## Bootstrap order


```
vpc ─▶ eks (cluster, system nodes: NotReady, pod-identity-agent)
          └─▶ cilium-bootstrap (nodes become Ready)
                 └─▶ CoreDNS addon ─▶ argocd-bootstrap ─▶ Argo CD adopts Cilium
```

## Usage

Called from the environment root (`envs/dev/main.tf`), after `module.vpc`:

```hcl
module "eks" {
  source = "../../modules/eks"

  project_name       = local.project_name
  cluster_name       = local.cluster_name
  kubernetes_version = "1.34"

  control_plane_subnet_ids = module.vpc.infra_subnet_ids
  node_subnet_ids          = module.vpc.infra_subnet_ids

  endpoint_public_access = true
  public_access_cidrs    = var.admin_cidrs # e.g. ["203.0.113.10/32"]

  # Don't include the identity running Terraform; it is added automatically.
  admin_principal_arns = [var.sso_admin_role_arn]

  system_node_instance_types = ["t3.large"]
  system_node_desired_size   = 2
  system_node_dedicated      = true

  tags = local.tags
}

# CoreDNS waits for Cilium; created too early it sits DEGRADED until timeout.
resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.cilium_bootstrap]
}
```

The root's Kubernetes and Helm providers read from the module outputs:

```hcl
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# Cilium:  k8sServiceHost = module.eks.cluster_endpoint_host
# Vault:   kubernetes_host / JWT issuer = module.eks.oidc_issuer_url
```

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| project_name | Project name for all associated resources | `string` | n/a |
| cluster_name | EKS cluster name (matches the VPC discovery tag) | `string` | n/a |
| kubernetes_version | Kubernetes minor version in standard support | `string` | n/a |
| support_type | `STANDARD` or `EXTENDED` | `string` | `"STANDARD"` |
| control_plane_subnet_ids | Control-plane ENI subnets (≥ 2 AZs) | `list(string)` | n/a |
| node_subnet_ids | System node group subnets | `list(string)` | n/a |
| service_ipv4_cidr | Kubernetes Service CIDR | `string` | `"172.20.0.0/16"` |
| endpoint_public_access | Expose the API server publicly | `bool` | `true` |
| public_access_cidrs | CIDRs allowed to reach the public endpoint | `list(string)` | `["0.0.0.0/0"]` |
| enabled_log_types | Control-plane log types | `list(string)` | `["api","audit","authenticator"]` |
| log_retention_days | Control-plane log retention | `number` | `30` |
| admin_principal_arns | Extra cluster-admin principals | `list(string)` | `[]` |
| system_node_instance_types | System node instance types | `list(string)` | `["t3.large"]` |
| system_node_ami_type | Managed node group AMI type | `string` | `"AL2023_x86_64_STANDARD"` |
| system_node_capacity_type | `ON_DEMAND` or `SPOT` | `string` | `"ON_DEMAND"` |
| system_node_min_size | Minimum system nodes | `number` | `2` |
| system_node_max_size | Maximum system nodes | `number` | `3` |
| system_node_desired_size | Initial system nodes | `number` | `2` |
| system_node_disk_size | Root volume size (GiB) | `number` | `50` |
| system_node_dedicated | Taint system nodes `CriticalAddonsOnly` | `bool` | `true` |
| tags | Tags merged onto all resources | `map(string)` | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| cluster_name | EKS cluster name |
| cluster_arn | EKS cluster ARN |
| cluster_version | Kubernetes version |
| cluster_endpoint | API server endpoint (https URL) |
| cluster_endpoint_host | Endpoint host without scheme (Cilium `k8sServiceHost`) |
| cluster_ca_data | Base64 cluster CA certificate |
| cluster_security_group_id | Cluster SG shared by control plane and all nodes |
| oidc_issuer_url | OIDC issuer for Vault Kubernetes/JWT auth |
| service_ipv4_cidr | Kubernetes Service CIDR |
| system_node_role_arn | System node IAM role ARN |
| system_node_group_name | System node group name |
| kms_key_arn | Secrets encryption KMS key ARN |
<!-- END_TF_DOCS -->