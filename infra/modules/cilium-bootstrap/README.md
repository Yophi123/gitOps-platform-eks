# cilium-bootstrap

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-1.20-F8C517)
![IPAM](https://img.shields.io/badge/IPAM-AWS%20ENI-FF9900)
![kube--proxy](https://img.shields.io/badge/kube--proxy-replaced-2E8B57)
![Hubble](https://img.shields.io/badge/Hubble-enabled-informational)

One-time Cilium install, applied right after the EKS control plane and **before
any nodes exist**, so the system nodes boot straight into a working CNI. Argo CD
adopts the release in stage 3, using the same release name, namespace and values.

## Design

- **Installed before nodes, `wait = false`.** With no nodes there is nothing to
  wait for. Waiting would deadlock, because the node group can't go `ACTIVE`
  until Cilium makes its nodes Ready.
- **ENI IPAM, native routing.** Pods get VPC-routable IPs, so the control plane
  can reach admission webhooks directly.
- **kube-proxy replacement.** `k8sServiceHost` points at the EKS endpoint, since
  there is no kube-proxy to provide the `kubernetes` Service.
- **Operator credentials via Pod Identity**, with only the EC2 privileges listed
  in Cilium's ENI docs. The association is created before the release, so the
  operator pods get credentials injected from their first start. The node role
  has no ENI permissions.
- **Operator tolerations.** The chart defaults don't include `CriticalAddonsOnly`,
  so they're overridden with the defaults plus that taint. Without it the operator
  can't schedule on the dedicated system nodes, CRDs never register, and the
  agents never finish starting.
- **No root-level `tolerations`.** The agent's default (tolerate everything) must
  stay as it is.
- **Hubble TLS via `cronJob`**, so renders are stable and Argo CD doesn't show drift.
- **Relay, UI and certgen tolerate `CriticalAddonsOnly`** so they run on the
  system nodes before Karpenter exists.

## Usage

```hcl
module "cilium_bootstrap" {
  source = "../../modules/cilium-bootstrap"

  project_name     = var.project_name
  cluster_name     = module.eks.cluster_name
  k8s_service_host = module.eks.cluster_endpoint_host
  vpc_cidr         = module.vpc.vpc_cidr
  chart_version    = "1.20.2"
}

# The node group waits for Cilium, not the other way round
module "eks" {
  # ...
  node_group_wait_for = [module.cilium_bootstrap.release_name]
}
```

Don't add `depends_on = [module.eks]` here. That pulls in the node group and
recreates the deadlock. The root must configure the `helm` provider against
the cluster.

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| project_name | Project name for all associated resources | `string` | n/a |
| cluster_name | EKS cluster name (Cilium `cluster.name`, ENI GC tags) | `string` | n/a |
| k8s_service_host | API server host without scheme | `string` | n/a |
| vpc_cidr | VPC CIDR (`ipv4NativeRoutingCIDR`) | `string` | n/a |
| chart_version | Cilium chart version (no leading v) | `string` | `"1.20.2"` |
| enable_prefix_delegation | /28 prefixes per ENI (Karpenter max-pods must match) | `bool` | `false` |
| hubble_ui_enabled | Deploy the Hubble UI | `bool` | `true` |
| tags | Tags merged onto AWS resources | `map(string)` | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| release_name | Helm release name (Argo CD must use the same) |
| release_namespace | Helm release namespace |
| chart_version | Installed chart version |
| operator_role_arn | Cilium operator IAM role |
| helm_values | Rendered values for Argo CD adoption |
<!-- END_TF_DOCS -->