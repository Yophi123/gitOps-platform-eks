# karpenter

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![Karpenter](https://img.shields.io/badge/Karpenter-1.15-2E8B57)
![Auth](https://img.shields.io/badge/auth-Pod%20Identity-FF9900)
![Interruption](https://img.shields.io/badge/interruption-SQS%20%2B%20EventBridge-informational)

AWS resources and controller install for Karpenter. `EC2NodeClass` and `NodePool`
live in Git (`gitops/platform/karpenter/`), not here.

## Design

- **Node role** without `AmazonEKS_CNI_Policy`: Cilium's operator owns ENIs.
  Nodes join through an `EC2_LINUX` access entry, with no aws-auth ConfigMap.
- **Controller role via Pod Identity**, with policies mirroring Karpenter's
  reference CloudFormation (scoped to this cluster's tags and region), split
  into managed policies to stay within IAM size limits.
- **Interruption handling**: an SQS queue (TLS-only, SSE) fed by EventBridge for
  Spot interruptions, rebalance recommendations, state changes, health events
  and capacity reservation interruptions.
- **Two Helm releases**: `karpenter-crd` (so CRDs upgrade) and `karpenter`
  (`skip_crds`).
- **Controller tolerates `CriticalAddonsOnly`** and runs on the system nodes. The
  chart's default affinity keeps it off nodes Karpenter itself launches.
- **Zonal shift is off**, so the zonal shift policy is omitted.

## Usage

```hcl
module "karpenter" {
  source = "../../modules/karpenter"

  project_name  = var.project_name
  cluster_name  = module.eks.cluster_name
  chart_version = "1.15.0"
  replicas      = min(2, var.system_node_desired_size)

  depends_on = [aws_eks_addon.coredns] # controller needs cluster DNS
}
```

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| project_name | Project name for all associated resources | `string` | n/a |
| cluster_name | EKS cluster name (queue name, discovery tag) | `string` | n/a |
| chart_version | Karpenter chart version (CRDs + controller) | `string` | `"1.15.0"` |
| replicas | Controller replicas (≤ system nodes) | `number` | `2` |
| create_spot_service_linked_role | Create `AWSServiceRoleForEC2Spot` | `bool` | `false` |
| tags | Tags merged onto AWS resources | `map(string)` | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| node_role_name | Node role name (`EC2NodeClass.spec.role`) |
| node_role_arn | Node role ARN |
| controller_role_arn | Controller role ARN |
| interruption_queue_name | SQS interruption queue name |
| release_name | Karpenter Helm release name |
| chart_version | Installed chart version |
| helm_values | Rendered values for Argo CD adoption |
<!-- END_TF_DOCS -->