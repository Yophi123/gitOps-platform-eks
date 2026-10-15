# GitOps Platform on EKS with Argo CD

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.10-7B42BC?logo=terraform&logoColor=white)
![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.34-FF9900)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-app--of--apps-EF7B4D?logo=argo&logoColor=white)
![Cilium](https://img.shields.io/badge/CNI-Cilium%20eBPF-F8C517)
![Karpenter](https://img.shields.io/badge/autoscaling-Karpenter-2E8B57)
![Vault](https://img.shields.io/badge/secrets-Vault%20%2B%20ESO-FFEC6E?logo=vault&logoColor=black)
![infra-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/infra-ci.yml/badge.svg)
![gitops-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/gitops-ci.yml/badge.svg)

A production-style EKS platform defined entirely as code. Terraform provisions
the AWS infrastructure and bootstraps the cluster. From then on, Argo CD
reconciles all cluster and application state from Git.

## Repository layout

```
.
├── .github/workflows/   # infra-ci, infra-apply, gitops-ci
├── infra/               # Terraform: AWS resources + cluster bootstrap
│   ├── envs/{dev,prod}/ # root wiring per environment
│   ├── modules/         # vpc, eks, cilium-bootstrap, karpenter, argocd-bootstrap, vault, ...
│   └── packer/          # Vault AMI
└── gitops/              # Argo CD: everything inside the cluster
    ├── bootstrap/       # root app-of-apps
    ├── platform/        # Cilium, Karpenter NodePools, ESO, Rollouts, monitoring, Kyverno
    ├── apps/            # workloads (Rollouts + AnalysisTemplates)
    └── envs/{dev,prod}/ # overlays
```

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.10 |
| AWS CLI | v2 |
| kubectl | within one minor version of the cluster |
| Helm | v3 |
| cilium CLI | latest (from stage 2) |

### One-time: Terraform state bucket

```bash
export REGION=eu-west-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export STATE_BUCKET=gitops-eks-tfstate-${ACCOUNT_ID}

aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Leave out `--create-bucket-configuration` in `us-east-1`. New buckets are encrypted
(SSE-S3) by default.

### Restrict the API endpoint to your IP

```bash
echo "admin_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Paste the output into `infra/envs/<env>/terraform.tfvars`. Re-run it and apply
whenever your IP changes.

---

## Stage 1: VPC + EKS

```bash
cd infra/envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This takes about 15 minutes. Most of that is the EKS control plane.

**Expected outputs**

```
Apply complete! Resources: NN added, 0 changed, 0 destroyed.

Outputs:

cluster_endpoint = "https://0123456789ABCDEF0123456789ABCDEF.gr7.eu-west-1.eks.amazonaws.com"
cluster_name = "gitops-eks-dev"
kubeconfig_command = "aws eks update-kubeconfig --region eu-west-1 --name gitops-eks-dev"
vpc_id = "vpc-0a1b2c3d4e5f67890"
```

### Connect kubectl

```bash
export CLUSTER=gitops-eks-dev
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
```

```
Added new context arn:aws:eks:eu-west-1:111122223333:cluster/gitops-eks-dev to /home/<user>/.kube/config
```

### Nodes: registered but NotReady (expected)

The cluster is created without aws-node, kube-proxy or CoreDNS. With no CNI, the
kubelet can't report Ready. The nodes stay NotReady until stage 2.

```bash
kubectl get nodes -o wide
```

```
NAME                                         STATUS     ROLES    AGE   VERSION               INTERNAL-IP    ...
ip-10-16-71-18.eu-west-1.compute.internal    NotReady   <none>   9m    v1.34.x-eks-xxxxxxx   10.16.71.18    ...
ip-10-16-150-204.eu-west-1.compute.internal  NotReady   <none>   9m    v1.34.x-eks-xxxxxxx   10.16.150.204  ...
```

Node IPs fall in the **infra** subnets: `10.16.64.0/20` (AZ a), `10.16.144.0/20`
(AZ b) and `10.16.224.0/20` (AZ c).

```bash
kubectl describe node <node-name> | grep -A7 Conditions
```

```
Conditions:
  Type             Status  Reason                       Message
  ----             ------  ------                       -------
  MemoryPressure   False   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure     False   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure      False   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready            False   KubeletNotReady              container runtime network not ready: NetworkReady=false
                                                        reason:NetworkPluginNotReady message:Network plugin
                                                        returns error: cni plugin not initialized
```

The timestamp columns are trimmed above. If the `Ready` reason is anything other
than the CNI message, see [Troubleshooting](#troubleshooting).

### Taints and labels

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,POOL:.metadata.labels.node-pool,TAINTS:.spec.taints[*].key'
```

```
NAME                                         POOL     TAINTS
ip-10-16-71-18.eu-west-1.compute.internal    system   node.cilium.io/agent-not-ready,CriticalAddonsOnly,node.kubernetes.io/not-ready
ip-10-16-150-204.eu-west-1.compute.internal  system   node.cilium.io/agent-not-ready,CriticalAddonsOnly,node.kubernetes.io/not-ready
```

### Pods

```bash
kubectl get pods -A
```

```
NAMESPACE     NAME                           READY   STATUS    RESTARTS   AGE
kube-system   eks-pod-identity-agent-xxxxx   1/1     Running   0          8m
kube-system   eks-pod-identity-agent-yyyyy   1/1     Running   0          8m
```

The Pod Identity agent runs on the host network, so it starts without a CNI.
There is no aws-node, kube-proxy or CoreDNS, which is intentional.

### Node group and addon health

```bash
aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
  --nodegroup-name "${CLUSTER}-system" \
  --query 'nodegroup.{status:status,health:health.issues}'
```

```json
{
    "status": "ACTIVE",
    "health": []
}
```

```bash
aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER" \
  --addon-name eks-pod-identity-agent --query 'addon.{status:status,health:health.issues}'
```

```json
{
    "status": "ACTIVE",
    "health": []
}
```

`DEGRADED` is acceptable here until Cilium is installed.

### Access entries

```bash
aws eks list-access-entries --region "$REGION" --cluster-name "$CLUSTER"
```

This should list the identity that ran Terraform, plus any `admin_principal_arns`.

**Stage 1 is complete when** the apply succeeds, kubectl connects, and both
nodes show `NotReady` with `cni plugin not initialized`.

---

## Stage 2: Cilium (ENI mode, kube-proxy replacement, Hubble)

_TODO: nodes become Ready; CoreDNS addon._

## Stage 3: Karpenter

_TODO_

## Stage 4: Argo CD (app-of-apps)

_TODO_

## Stage 5: Vault + External Secrets Operator

_TODO_

## Stage 6: Argo Rollouts canary

_TODO_

## Stage 7: CI/CD and policy

_TODO_

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `kubectl` returns `i/o timeout` | Your IP changed; the endpoint is restricted to `admin_cidrs` | Re-run the IP command, then `terraform apply` |
| `kubectl` returns `the server has asked for the client to provide credentials` | Your identity has no access entry | `aws sts get-caller-identity`, then compare with `list-access-entries` |
| Node group `CREATE_FAILED` / `NodeCreationFailure` | Node IAM role or subnet routing | `describe-nodegroup` health issues; the private route table should have NAT |
| Node `Ready` reason isn't the CNI message | Kubelet or instance issue | `aws ssm start-session --target <instance-id>`, then `journalctl -u kubelet` |

## Teardown

```bash
cd infra/envs/dev
terraform destroy
```

Once Karpenter is installed (stage 3), delete its NodePools first so it terminates
its instances. Instances left behind keep ENIs in the VPC and block the destroy.