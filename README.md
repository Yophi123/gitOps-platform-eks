# GitOps Platform on EKS with Argo CD

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.10-7B42BC?logo=terraform&logoColor=white)
![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.34-FF9900)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-app--of--apps-EF7B4D?logo=argo&logoColor=white)
![Cilium](https://img.shields.io/badge/CNI-Cilium%201.20%20eBPF-F8C517)
![Karpenter](https://img.shields.io/badge/autoscaling-Karpenter-2E8B57)
![Vault](https://img.shields.io/badge/secrets-Vault%20%2B%20ESO-FFEC6E?logo=vault&logoColor=black)
![infra-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/infra-ci.yml/badge.svg)
![gitops-ci](https://github.com/github.com/Yophi123/gitOps-platform-eks/actions/workflows/gitops-ci.yml/badge.svg)

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
| cilium CLI | latest |
| hubble CLI | latest |

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

### Commit the provider lock file

Commit `infra/envs/<env>/.terraform.lock.hcl`, and run `terraform init -upgrade`
only when you mean to upgrade providers. An unplanned AWS provider upgrade can
propose replacing the EKS cluster.

---

## Stage 1: Cluster bootstrap (VPC, EKS, Cilium, CoreDNS)

The cluster is created without aws-node, kube-proxy or CoreDNS, so this stage is
one apply. The node group can't go `ACTIVE` until Cilium makes its nodes Ready,
so Cilium installs in parallel with the node group rather than after it:

```
vpc ─▶ EKS control plane ─┬─▶ system node group (CREATING, nodes register NotReady)
                          └─▶ pod-identity-agent ─▶ Cilium
                                                      │
                                nodes Ready ◀─────────┘
                                     │
                     node group ACTIVE ─▶ CoreDNS addon
```

```bash
cd infra/envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This takes about 20 minutes: roughly 12 for the control plane, then the node
group, Cilium and CoreDNS.

### Expected outputs

```
Apply complete! Resources: NN added, 0 changed, 0 destroyed.

Outputs:

cilium_chart_version = "1.20.2"
cluster_endpoint = "https://0123456789ABCDEF0123456789ABCDEF.gr7.eu-west-1.eks.amazonaws.com"
cluster_name = "gitops-eks-dev"
kubeconfig_command = "aws eks update-kubeconfig --region eu-west-1 --name gitops-eks-dev"
vpc_id = "vpc-0a1b2c3d4e5f67890"
```

### Connect kubectl

You can do this as soon as the control plane exists, while the apply is still running.

```bash
export CLUSTER=gitops-eks-dev
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
```

```
Added new context arn:aws:eks:eu-west-1:111122223333:cluster/gitops-eks-dev to /home/<user>/.kube/config
```

### During the apply: nodes NotReady (expected)

While the node group is `CREATING` and before Cilium is running, nodes register
but report NotReady:

```bash
kubectl get nodes
```

```
NAME                                         STATUS     ROLES    AGE   VERSION
ip-10-16-71-18.eu-west-1.compute.internal    NotReady   <none>   2m    v1.34.x-eks-xxxxxxx
ip-10-16-150-204.eu-west-1.compute.internal  NotReady   <none>   2m    v1.34.x-eks-xxxxxxx
```

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

The timestamp columns are trimmed above. Watch Cilium arrive:

```bash
kubectl -n kube-system get pods -o wide -w
```

The `eks-pod-identity-agent-*`, `cilium-*` and `cilium-operator-*` pods appear
and go Running. Within a couple of minutes the nodes flip to Ready.

### After the apply: nodes Ready

```bash
kubectl get nodes -o wide
```

```
NAME                                         STATUS   ROLES    AGE   VERSION               INTERNAL-IP
ip-10-16-71-18.eu-west-1.compute.internal    Ready    <none>   12m   v1.34.x-eks-xxxxxxx   10.16.71.18
ip-10-16-150-204.eu-west-1.compute.internal  Ready    <none>   12m   v1.34.x-eks-xxxxxxx   10.16.150.204
```

Node IPs fall in the **infra** subnets: `10.16.64.0/20` (AZ a), `10.16.144.0/20`
(AZ b) and `10.16.224.0/20` (AZ c).

### Taints and labels

The `node.cilium.io/agent-not-ready` taint has been removed by Cilium.
`CriticalAddonsOnly` remains, keeping workloads off the system nodes.

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,POOL:.metadata.labels.node-pool,TAINTS:.spec.taints[*].key'
```

```
NAME                                         POOL     TAINTS
ip-10-16-71-18.eu-west-1.compute.internal    system   CriticalAddonsOnly
ip-10-16-150-204.eu-west-1.compute.internal  system   CriticalAddonsOnly
```

### Cilium health

```bash
cilium status --wait
```

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet              cilium             Desired: 2, Ready: 2/2, Available: 2/2
DaemonSet              cilium-envoy       Desired: 2, Ready: 2/2, Available: 2/2
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay       Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui          Desired: 1, Ready: 1/1, Available: 1/1
```

kube-proxy replacement is active:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement
```

```
KubeProxyReplacement:    True   [ens5   10.16.71.18 fe80::... (Direct Routing)]
```

ENI IPAM is active. Each node has a `CiliumNode` with ENIs created by the operator:

```bash
kubectl get ciliumnodes
kubectl get ciliumnode <node-name> -o jsonpath='{range .status.eni.enis.*}{.id}{"  "}{.subnet.cidr}{"\n"}{end}'
```

```
eni-0a1b2c3d4e5f60001  10.16.64.0/20
eni-0a1b2c3d4e5f60002  10.16.64.0/20
```

### Pods

```bash
kubectl get pods -n kube-system -o wide
```

```
NAME                               READY   STATUS    IP              NODE
cilium-4xk2p                       1/1     Running   10.16.71.18     ip-10-16-71-18...
cilium-9mzrt                       1/1     Running   10.16.150.204   ip-10-16-150-204...
cilium-envoy-...                   1/1     Running   10.16.71.18     ip-10-16-71-18...
cilium-operator-...                1/1     Running   10.16.150.204   ip-10-16-150-204...
coredns-6b9575c64c-4kq2x           1/1     Running   10.16.68.142    ip-10-16-71-18...
coredns-6b9575c64c-r7m9d           1/1     Running   10.16.153.37    ip-10-16-150-204...
eks-pod-identity-agent-xxxxx       1/1     Running   10.16.71.18     ip-10-16-71-18...
hubble-relay-...                   1/1     Running   10.16.66.21     ip-10-16-71-18...
hubble-ui-...                      2/2     Running   10.16.149.88    ip-10-16-150-204...
```

Host-network pods (Cilium, the operator and the Pod Identity agent) use the node
IP. Everything else gets its own VPC IP from the infra subnets. There is
intentionally no aws-node or kube-proxy.

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
for addon in eks-pod-identity-agent coredns; do
  aws eks describe-addon --region "$REGION" --cluster-name "$CLUSTER" \
    --addon-name "$addon" --query 'addon.[addonName,status]' --output text
done
```

```
eks-pod-identity-agent  ACTIVE
coredns                 ACTIVE
```

### Hubble

```bash
cilium hubble port-forward &
hubble observe --namespace kube-system --last 10
cilium hubble ui # opens http://localhost:12000
```

### Access entries

```bash
aws eks list-access-entries --region "$REGION" --cluster-name "$CLUSTER"
```

This should list the identity that ran Terraform, plus any `admin_principal_arns`.

### Re-plan is clean

```bash
terraform plan
```

```
No changes. Your infrastructure matches the configuration.
```

**Stage 1 is complete when** both nodes are `Ready`, the node group and addons are
`ACTIVE`, `cilium status` is all OK, CoreDNS pods have VPC IPs, and a re-plan
shows no changes.

`cilium connectivity test` is deferred to stage 2. Its test pods don't tolerate
`CriticalAddonsOnly`, so they need Karpenter nodes to schedule.

---

## Stage 2: Karpenter

_TODO: includes `cilium connectivity test` on Karpenter nodes._

## Stage 3: Argo CD (app-of-apps, adopts Cilium)

_TODO_

## Stage 4: Vault + External Secrets Operator

_TODO_

## Stage 5: Argo Rollouts canary

_TODO_

## Stage 6: CI/CD and policy

_TODO_

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| Plan wants to replace `module.eks.aws_eks_cluster.this` | Provider upgraded by `init -upgrade` | Look for `# forces replacement` in the plan; restore `.terraform.lock.hcl` |
| `aws_eks_node_group.system` stuck `Still creating` with no pods in `kube-system` | Cilium or the Pod Identity agent is waiting on the node group (dependency loop) | Cilium must depend only on `pod_identity_agent_addon_arn`, never on `module.eks` as a whole |
| Node group `CREATE_FAILED` / `NodeCreationFailure` | Nodes never became Ready | Fix the cause, then re-apply; Terraform replaces the node group |
| Interrupted apply left the node group tainted | Ctrl+C during create | `terraform untaint module.eks.aws_eks_node_group.system` |
| `kubectl` returns `i/o timeout` | Your IP changed; the endpoint is restricted to `admin_cidrs` | Re-run the IP command, then `terraform apply` |
| `kubectl` returns `the server has asked for the client to provide credentials` | Your identity has no access entry | `aws sts get-caller-identity`, then compare with `list-access-entries` |
| `helm_release.cilium` times out, operator `CrashLoopBackOff` | No AWS credentials for the operator | `kubectl -n kube-system logs deploy/cilium-operator`; check the Pod Identity association and agent |
| Pods stuck `ContainerCreating`: `no IPs available` | Operator can't create ENIs | Operator logs for `UnauthorizedOperation`; subnet free IPs |
| Pods on secondary ENIs lose connectivity | OS network tooling managing Cilium's ENIs | Cilium ENI docs, "Node Configuration": mark non-primary interfaces unmanaged |
| Hubble Relay `Pending` | Missing `CriticalAddonsOnly` toleration | `kubectl describe pod -n kube-system -l k8s-app=hubble-relay` |
| Node `Ready` reason isn't the CNI message | Kubelet or instance issue | `aws ssm start-session --target <instance-id>`, then `journalctl -u kubelet` |

## Teardown

```bash
cd infra/envs/dev
terraform destroy
```

Once Karpenter is installed (stage 2), delete its NodePools first so it terminates
its instances. Instances left behind keep ENIs in the VPC and block the destroy.