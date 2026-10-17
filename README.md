# GitOps Platform on EKS with Argo CD

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.10-7B42BC?logo=terraform&logoColor=white)
![Packer](https://img.shields.io/badge/Packer-Vault%20AMI-02A8EF?logo=packer&logoColor=white)
![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.34-FF9900)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-app--of--apps-EF7B4D?logo=argo&logoColor=white)
![Cilium](https://img.shields.io/badge/CNI-Cilium%201.20%20eBPF-F8C517)
![Karpenter](https://img.shields.io/badge/autoscaling-Karpenter%201.15-2E8B57)
![Vault](https://img.shields.io/badge/secrets-Vault%20%2B%20ESO-FFEC6E?logo=vault&logoColor=black)
![infra-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/infra-ci.yml/badge.svg)
![gitops-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/gitops-ci.yml/badge.svg)

A production-style EKS platform defined entirely as code. Terraform provisions
the AWS infrastructure and bootstraps the cluster. From then on, Argo CD
reconciles all cluster and application state from Git.

## What it does

| Area | Implementation |
|------|----------------|
| Infrastructure as code | Terraform modules for VPC, EKS, Cilium, Karpenter, Argo CD, Vault and RDS; Packer for the Vault AMI |
| GitOps | Argo CD app-of-apps: one root Application, everything else reconciled from `gitops/`, including Argo CD itself |
| Networking | Cilium replaces the VPC CNI and kube-proxy: ENI IPAM, eBPF datapath, network policies, Hubble flow visibility |
| Autoscaling | Karpenter instead of Cluster Autoscaler: just-in-time nodes, Spot first, consolidation and Spot-to-Spot replacement |
| Secrets | 3-node Vault (Raft, KMS auto-unseal) + External Secrets Operator: workloads get short-lived Postgres users, no static credentials |
| Progressive delivery | Argo Rollouts canaries with automated analysis and rollback (stage 5) |
| CI/CD and policy | GitHub Actions: lint, diff and policy checks, promotion by pull request (stage 6) |

### No static credentials anywhere in the chain

```
pod service-account token (aud: vault, ~1h)
  └─▶ Vault JWT auth (validated against the EKS OIDC issuer; no reviewer token)
        └─▶ database/creds/<app> ─▶ Postgres user that expires after 1h
                                     (RDS master password known only to Vault)
```

## Repository layout

```
.
├── .github/workflows/          # infra-ci, infra-apply, gitops-ci (stage 6)
├── Makefile                    # day-to-day commands: make help
├── scripts/
│   ├── dev.env                 # the one settings file per environment
│   ├── render.sh               # renders gitops/ from dev.env + Terraform outputs
│   ├── check.sh                # placeholders, empty files, paths, kustomize builds
│   └── templates/              # sources for every rendered GitOps file
├── packer/
│   └── vault/                  # Ubuntu 26.04 + Vault AMI
├── infra/                      # Terraform
│   ├── envs/
│   │   ├── dev/                # platform root: VPC, EKS, Cilium, Karpenter, Argo CD, Vault, RDS
│   │   └── dev-vault/          # Vault configuration root (applied through an SSM tunnel)
│   └── modules/                # vpc, eks, cilium-bootstrap, karpenter, argocd-bootstrap,
│                               # vault-cluster, rds, vault-config
└── gitops/                     # Argo CD: everything inside the cluster
    ├── envs/dev/
    │   ├── apps/               # Applications + AppProjects (rendered; root app watches this)
    │   └── values/             # Helm values per component
    ├── platform/
    │   └── karpenter/          # EC2NodeClass (rendered) + NodePool
    └── apps/
        └── demo/               # workload using dynamic DB credentials
```

Files marked "rendered" are written by `make render`. Each one carries a header
pointing at its template in `scripts/templates/`. Edit the template, not the
rendered file.

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.10 |
| Packer | >= 1.11 |
| AWS CLI | v2 |
| [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | latest |
| kubectl | within one minor version of the cluster |
| Helm | v3 |
| Vault CLI | matches the AMI |
| cilium CLI, hubble CLI | latest |
| make, git, jq | any |

---

## Configuration

### 1. Terraform state bucket (once per account)

```bash
export REGION=ap-southeast-1
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

Leave out `--create-bucket-configuration` in `us-east-1`. New buckets are
encrypted (SSE-S3) by default. The state holds the Vault TLS key and the initial
RDS password, so restrict access to the bucket.

### 2. Spot service-linked role (once per account)

```bash
aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1 \
  || aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

### 3. `scripts/dev.env`

The single settings file for GitOps rendering and the Makefile: region, cluster
name, Git repository and chart versions.

```bash
ENV=dev
AWS_REGION=ap-southeast-1
CLUSTER_NAME=gitops-eks-dev
GITOPS_REPO_URL=https://github.com/Yophi123/gitOps-platform-eks.git
GITOPS_REVISION=main
CILIUM_VERSION=1.20.2
KARPENTER_VERSION=1.15.0
ARGOCD_CHART_VERSION=10.10.5
ESO_CHART_VERSION=<helm search repo external-secrets/external-secrets>
```

Keep the Cilium, Karpenter and Argo CD versions equal to the matching values in
`infra/envs/dev/terraform.tfvars`. `make render` warns when they differ.

### 4. `infra/envs/dev/terraform.tfvars`

Restrict the EKS API endpoint to your IP:

```bash
echo "admin_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Paste the output into `terraform.tfvars`. If your ISP rotates addresses,
`kubectl` and Terraform start failing with `i/o timeout`; re-run the command and
`make apply`. The endpoint update takes 2 to 5 minutes.

### 5. Commit the provider lock file

Commit `infra/envs/<env>/.terraform.lock.hcl`, and run `terraform init -upgrade`
only when you mean to upgrade providers. An unplanned AWS provider upgrade can
propose replacing the EKS cluster.

---

## Quick start

```bash
make ami                 # once per Vault version
make bootstrap           # core → render/push → full apply → render/push
make vault-shell         # once: vault operator init -recovery-shares=1 -recovery-threshold=1
make vault-tunnel        # separate terminal, leave running
eval "$(make -s vault-env)"
export VAULT_TOKEN=...   # root token from init
make vault-config
make status
```

### Why bootstrap runs in two phases

The Cilium values in Git contain the cluster's API endpoint, which changes
whenever the cluster is recreated. `make bootstrap` therefore:

1. `make core`: applies only up to Karpenter (VPC, EKS, Cilium, CoreDNS, Karpenter).
2. `make push`: renders `gitops/` with the new endpoint, checks it, commits and pushes.
3. `make apply`: full apply, which installs Argo CD (adopting Cilium and Karpenter
   with the fresh values), Vault and RDS.
4. `make push`: renders again, now that the Vault and RDS endpoints exist.

## Operations

| Task | Command |
|------|---------|
| List all targets | `make help` |
| Build the Vault AMI | `make ami` |
| Fresh environment, end to end | `make bootstrap` |
| Infrastructure changes | `make apply` |
| GitOps changes after an apply (new endpoints, versions) | `make push` |
| Render or check without pushing | `make render` / `make check` |
| Point kubectl at the cluster | `make kubeconfig` |
| Argo CD status / force a sync | `make status` / `make sync APP=demo` |
| Shell on a Vault node | `make vault-shell` |
| Vault CLI from your machine | `make vault-tunnel` (own terminal), then `eval "$(make -s vault-env)"` |
| Apply Vault config | `export VAULT_TOKEN=...` then `make vault-config` |
| Karpenter leftovers check | `make leftovers` |
| Tear down | `make destroy` |

`make check` runs inside `make push` and stops on leftover placeholders, empty
files, broken kustomizations, and Applications pointing at paths that don't exist.

---

## Stage 1: Cluster bootstrap (VPC, EKS, Cilium, CoreDNS)

The cluster is created without aws-node, kube-proxy or CoreDNS. A managed node
group only goes `ACTIVE` once its nodes are Ready, and nodes are only Ready once a
CNI runs. So Cilium is installed right after the control plane, **before any
nodes exist**, and the node group is created after it:

```
vpc ─▶ EKS control plane ─▶ Pod Identity association ─▶ Cilium (Helm, no wait)
              │                                                │
              └─▶ pod-identity-agent addon                     ▼
                                              system node group (nodes boot Ready)
                                                               ▼
                                                         CoreDNS addon
```

Stages 1 and 2 are one command:

```bash
make core
make kubeconfig
```

This takes about 20 minutes: roughly 12 for the control plane, then the Cilium
release (seconds, since it doesn't wait), the node group, CoreDNS and Karpenter.

### Expected outputs

```
Apply complete! Resources: NN added, 0 changed, 0 destroyed.

Outputs:

cilium_chart_version = "1.20.2"
cluster_endpoint = "https://0123456789ABCDEF0123456789ABCDEF.gr7.ap-southeast-1.eks.amazonaws.com"
cluster_name = "gitops-eks-dev"
kubeconfig_command = "aws eks update-kubeconfig --region ap-southeast-1 --name gitops-eks-dev"
vpc_id = "vpc-0a1b2c3d4e5f67890"
```

### During the apply

Cilium's objects exist before any nodes, so its pods are Pending with
`no nodes available to schedule pods`. That's expected. When the node group's
instances join, they briefly show NotReady with `cni plugin not initialized`,
then turn Ready once the Cilium agent and operator start:

```bash
kubectl -n kube-system get pods -o wide -w
```

Startup order on each node: `cilium-*` and `eks-pod-identity-agent-*` (host
network) → `cilium-operator-*` registers Cilium's CRDs and allocates ENI IPs →
the agent finishes and removes the `node.cilium.io/agent-not-ready` taint → the
node is Ready → CoreDNS schedules.

### Nodes Ready

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,POOL:.metadata.labels.node-pool,READY:.status.conditions[?(@.type=="Ready")].status,TAINTS:.spec.taints[*].key'
```

```
NAME                                              POOL     READY   TAINTS
ip-10-16-74-132.ap-southeast-1.compute.internal   system   True    CriticalAddonsOnly
ip-10-16-235-69.ap-southeast-1.compute.internal   system   True    CriticalAddonsOnly
```

Node IPs fall in the **infra** subnets: `10.16.64.0/20` (AZ a), `10.16.144.0/20`
(AZ b) and `10.16.224.0/20` (AZ c). Only `CriticalAddonsOnly` remains, keeping
workloads off the system nodes. Everything scheduled there must tolerate it.

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

kube-proxy replacement and ENI IPAM are active:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement
kubectl get ciliumnode <node-name> -o jsonpath='{range .status.eni.enis.*}{.id}{"  "}{.subnet.cidr}{"\n"}{end}'
```

```
KubeProxyReplacement:    True   [ens5   10.16.74.132 fe80::... (Direct Routing)]
eni-0a1b2c3d4e5f60001  10.16.64.0/20
eni-0a1b2c3d4e5f60002  10.16.64.0/20
```

### Pods

```bash
kubectl get pods -n kube-system -o wide
```

```
NAME                               READY   STATUS    IP              NODE
cilium-4xk2p                       1/1     Running   10.16.74.132    ip-10-16-74-132...
cilium-9mzrt                       1/1     Running   10.16.235.69    ip-10-16-235-69...
cilium-operator-...                1/1     Running   10.16.74.132    ip-10-16-74-132...
cilium-operator-...                1/1     Running   10.16.235.69    ip-10-16-235-69...
coredns-567446cf5f-b8kvn           1/1     Running   10.16.70.18     ip-10-16-74-132...
coredns-567446cf5f-w2zp5           1/1     Running   10.16.229.141   ip-10-16-235-69...
eks-pod-identity-agent-xxxxx       1/1     Running   10.16.74.132    ip-10-16-74-132...
hubble-relay-...                   1/1     Running   10.16.66.21     ip-10-16-74-132...
hubble-ui-...                      2/2     Running   10.16.231.88    ip-10-16-235-69...
```

Host-network pods (Cilium, the operator and the Pod Identity agent) use the node
IP. Everything else gets its own VPC IP from the infra subnets. There is
intentionally no aws-node or kube-proxy.

### Node group and addon health

```bash
aws eks describe-nodegroup --region "$REGION" --cluster-name gitops-eks-dev \
  --nodegroup-name gitops-eks-dev-system --query 'nodegroup.{status:status,health:health.issues}'

for addon in eks-pod-identity-agent coredns; do
  aws eks describe-addon --region "$REGION" --cluster-name gitops-eks-dev \
    --addon-name "$addon" --query 'addon.[addonName,status]' --output text
done
```

```
{ "status": "ACTIVE", "health": [] }
eks-pod-identity-agent  ACTIVE
coredns                 ACTIVE
```

Addon health lags a few minutes behind the pods. A stale `DEGRADED` that clears
on its own is normal. `kubectl get pdb -n kube-system coredns` showing
`ALLOWED DISRUPTIONS 1` means both CoreDNS replicas are healthy.

### Hubble

```bash
cilium hubble port-forward &
hubble observe --namespace kube-system --last 10
cilium hubble ui   # opens http://localhost:12000
```

**Stage 1 is complete when** both nodes are `Ready` with only the
`CriticalAddonsOnly` taint, the node group and addons are `ACTIVE`,
`cilium status` is all OK, and CoreDNS pods have VPC IPs.

---

## Stage 2: Karpenter

Terraform creates the AWS side (node role and access entry, controller role,
SQS interruption queue with EventBridge rules) and installs the controller as
part of `make core`. The `EC2NodeClass` and `NodePool` live in
`gitops/platform/karpenter/`; Argo CD applies them from stage 3 on.

The NodePool is amd64 only, Spot first with On-Demand fallback, `c`/`m`/`r`
families from generation 6, and no `nano`/`micro`/`small` sizes (they have too
few ENI IPs for Cilium's ENI mode). Spot-to-Spot consolidation is enabled.

To test Karpenter before Argo CD exists, render and apply the node manifests once:

```bash
make render
kubectl apply -k gitops/platform/karpenter/
```

### Controller and node configuration

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide
kubectl get ec2nodeclass,nodepool
```

```
NAME                         READY   STATUS    NODE
karpenter-6d8f7c9b5d-7xk2p   1/1     Running   ip-10-16-74-132...
karpenter-6d8f7c9b5d-q9m4t   1/1     Running   ip-10-16-235-69...

NAME                                     READY   AGE
ec2nodeclass.karpenter.k8s.aws/default   True    1m

NAME                            NODECLASS   NODES   READY   AGE
nodepool.karpenter.sh/general   default     0       True    1m
```

One controller replica per system node; only the leader acts. If the
EC2NodeClass is not `Ready`, `kubectl describe ec2nodeclass default` shows which
selector (AMI, subnet, security group) or instance profile failed.

### Scale-up test

```bash
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7 --replicas=0
kubectl set resources deployment inflate --requests=cpu=1
kubectl scale deployment inflate --replicas=5

kubectl get nodeclaims
kubectl get nodes -L node-pool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

```
NAME            TYPE          CAPACITY   ZONE              NODE                                               READY
general-x7k2p   c6a.2xlarge   spot       ap-southeast-1a   ip-10-16-41-87.ap-southeast-1.compute.internal     True

NAME                                              STATUS   NODE-POOL   CAPACITY-TYPE   INSTANCE-TYPE
ip-10-16-41-87.ap-southeast-1.compute.internal    Ready    general     spot            c6a.2xlarge
ip-10-16-74-132.ap-southeast-1.compute.internal   Ready    system                      t3.large
ip-10-16-235-69.ap-southeast-1.compute.internal   Ready    system                      t3.large
```

The new node's IP falls in an **app** subnet: `10.16.32.0/20` (AZ a),
`10.16.112.0/20` (AZ b) or `10.16.192.0/20` (AZ c). Its Cilium startup taint is
gone, and the `inflate` pods run there with VPC IPs from the same subnet.

### Network connectivity test

Now that untainted nodes exist. The Hubble port-forward enables flow validation
in the test:

```bash
cilium hubble port-forward &
cilium connectivity test
kill %1
```

```
✅ [gitops-eks-dev] All NN tests (NNN actions) successful, N tests skipped, 0 scenarios skipped.
```

Remove the test namespaces afterwards. Leftover test pods keep their node from
being consolidated:

```bash
kubectl delete ns cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2 --ignore-not-found
```

### Consolidation test

```bash
kubectl delete deployment inflate
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -c controller -f | grep '"decision"'
```

About a minute after the node empties, Karpenter deletes it (`"decision":"delete"`).
An underutilized Spot node that still runs pods is replaced with a cheaper Spot
node instead (`"decision":"replace"`).

```bash
kubectl get nodeclaims   # No resources found
```

**Stage 2 is complete when** the EC2NodeClass and NodePool are `Ready`, a
scale-up lands pods on a Spot node in an app subnet, `cilium connectivity test`
passes, and the node is removed after scale-down.

---

## Stage 3: Argo CD (app-of-apps)

Terraform installs Argo CD and one root Application. The root app syncs
`gitops/envs/dev/apps/`, which takes over Cilium and Karpenter from their
bootstrap Helm releases (same release names and values), deploys the NodePool,
and makes Argo CD manage itself. From here on, cluster changes go through Git.

```
root ─▶ platform + apps projects (-10) ─▶ cilium, karpenter-crd (0) ─▶ karpenter (1)
     ─▶ karpenter-nodes (2) ─▶ external-secrets (3) ─▶ demo (5) ─▶ argocd (10)
```

Every Application uses the same sync policy: automated sync with self-heal,
`retry` with backoff (so CRD ordering races resolve themselves),
`ServerSideApply` and `CreateNamespace`. Platform Applications have no deletion
finalizer: removing `cilium` from Git must never uninstall the CNI.

```bash
make push                                                   # values must be in Git first
terraform -chdir=infra/envs/dev apply -target=module.argocd_bootstrap
```

A plain `make apply` also works once the Vault AMI exists (it creates Vault and
RDS as well; see stage 4).

### Applications synced and healthy

```bash
make status
```

```
NAME               SYNC STATUS   HEALTH STATUS
argocd             Synced        Healthy
cilium             Synced        Healthy
demo               Synced        Healthy
external-secrets   Synced        Healthy
karpenter          Synced        Healthy
karpenter-crd      Synced        Healthy
karpenter-nodes    Synced        Healthy
root               Synced        Healthy
```

`demo` and `external-secrets` only turn healthy after stage 4. Argo CD
components run on the system nodes:

```bash
kubectl -n argocd get pods -o wide   # every NODE is a system node
```

### UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

Open http://localhost:8080 and log in as `admin`. Then change the password and
delete the `argocd-initial-admin-secret` Secret.

### Prove Git is the source of truth

**Drift is reverted (self-heal):**

```bash
kubectl patch nodepool general --type=merge -p '{"spec":{"limits":{"cpu":"4"}}}'
sleep 20
kubectl get nodepool general -o jsonpath='{.spec.limits.cpu}{"\n"}'   # 32
```

**Changes flow from Git:** edit `limits.cpu` in
`gitops/platform/karpenter/nodepool.yaml`, commit and push. Within about
3 minutes (`timeout.reconciliation`), or right away with `make sync APP=karpenter-nodes`,
the cluster shows the new value.

**Stage 3 is complete when** all platform Applications are `Synced`/`Healthy`,
a manual change is reverted, and a Git change reaches the cluster without `kubectl`.

---

## Stage 4: Vault + External Secrets Operator

```
                  pods / nodes (cluster SG)
                            │ 8200
                 ┌──────────▼──────────┐
                 │  internal NLB (SG)  │  infra subnets, 3 AZs
                 └──────────┬──────────┘
            8200 ┌──────────┼──────────┐
           ┌─────▼───┐ ┌────▼────┐ ┌───▼─────┐
           │ vault-a │ │ vault-b │ │ vault-c │  ASG of 3, Raft storage
           └────┬────┘ └────┬────┘ └────┬────┘  8201 cluster traffic
                └───────────┴───────────┘
              KMS auto-unseal · auto-join by tag · TLS from SSM
                            │ 5432
                     ┌──────▼───────┐
                     │ RDS Postgres │  db subnets
                     └──────────────┘
```

### 4a. Vault cluster and RDS

```bash
make ami      # Ubuntu 26.04 + Vault, tagged Component=vault for the module
make apply
make push     # Vault and RDS endpoints now exist; renders the demo workload
```

Three Vault nodes start and wait to join a leader. Initialize the cluster once,
on any node:

```bash
make vault-shell
```

On the node (the Vault CLI is preconfigured for `https://127.0.0.1:8200`):

```bash
sudo -i
vault status                  # Initialized false, Sealed true, Seal Type awskms
vault operator init -recovery-shares=1 -recovery-threshold=1
```

Store the **recovery key** and **initial root token** in your password manager.
Nothing else has a copy.

```bash
export VAULT_TOKEN=<root token>
vault operator raft list-peers
```

```
Node                   Address              State       Voter
----                   -------              -----       -----
i-0a1b2c3d4e5f60001    10.16.70.12:8201     leader      true
i-0a1b2c3d4e5f60002    10.16.150.33:8201    follower    true
i-0a1b2c3d4e5f60003    10.16.231.8:8201     follower    true
```

All three are voters, and the followers unsealed themselves through KMS. The NLB
reports all three targets healthy:

```bash
aws elbv2 describe-target-health --region "$REGION" \
  --target-group-arn $(aws elbv2 describe-target-groups --region "$REGION" \
    --names gitops-eks-dev-vault-tg --query 'TargetGroups[0].TargetGroupArn' --output text) \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
```

```
["healthy", "healthy", "healthy"]
```

Pods reach Vault through the NLB:

```bash
kubectl run vault-check --rm -i --restart=Never --quiet --image=curlimages/curl \
  --overrides='{"spec":{"tolerations":[{"key":"CriticalAddonsOnly","operator":"Exists"}]}}' -- \
  sh -c "sleep 2; curl -sk $(terraform -chdir=infra/envs/dev output -raw vault_addr)/v1/sys/health"
```

The output is JSON with `"initialized":true,"sealed":false`.

**4a is complete when** three peers are voters, all NLB targets are healthy,
and a pod can reach `sys/health`.

### 4b. Vault configuration (Terraform over SSM)

`infra/envs/dev-vault` configures Vault as code: JWT auth against the EKS OIDC
issuer, the database secrets engine (one role per workload), policies, KV v2 and
Raft autopilot. It also hands the RDS master password to Vault, which rotates it
immediately.

Open the tunnel in its own terminal. It forwards `localhost:8200` straight to a
Vault node (the certificate covers `localhost`; standbys forward to the leader):

```bash
make vault-tunnel
```

In another terminal:

```bash
eval "$(make -s vault-env)"   # VAULT_ADDR and VAULT_CACERT
export VAULT_TOKEN=<root token from 4a>
vault status
make vault-config
```

#### Verify

```bash
vault auth list                                        # jwt-eks/  jwt
vault secrets list                                     # database/  secret/
vault read sys/storage/raft/autopilot/configuration    # cleanup_dead_servers true, min_quorum 3
```

Dynamic credentials work and connect:

```bash
vault read database/creds/demo
```

```
Key                Value
---                -----
lease_id           database/creds/demo/AbCd...
lease_duration     1h
username           v-root-demo-AZBT8BtZIGEVneGs10wz-1792270603
password           <password>
```

```bash
kubectl run psql --rm -i --restart=Never --quiet --image=postgres:18 \
  --overrides='{"spec":{"tolerations":[{"key":"CriticalAddonsOnly","operator":"Exists"}]}}' \
  --env=PGPASSWORD=<password> -- \
  sh -c 'sleep 2; psql "host=<rds_address> dbname=<rds_db_name> user=<username> sslmode=require" -c "select current_user;"'
```

```
                current_user
---------------------------------------------
 v-root-demo-AZBT8BtZIGEVneGs10wz-1792270603
(1 row)
```

The username carries the requesting identity (`v-root-` for the root token,
`v-jwt-eks-` for workloads) and its expiry timestamp. Revoking the lease drops
the user:

```bash
vault lease revoke -prefix database/creds/demo
# re-run psql → FATAL: password authentication failed
```

Only Vault knows the master password. The original one in Secrets Manager no
longer works:

```bash
aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$(terraform -chdir=infra/envs/dev output -raw rds_master_secret_arn)" \
  --query SecretString --output text | jq -r .password
# psql as vault_admin with that password → FATAL: password authentication failed
```

A pod's service-account token logs in as its own role, and only that role:

```bash
JWT=$(kubectl -n demo create token demo-app --audience vault)
vault write auth/jwt-eks/login role=demo jwt="$JWT"
```

```
Key                  Value
---                  -----
token_policies       ["default" "demo-db"]
token_meta_role      demo
```

A token for a different service account is rejected
(`error validating claims: claim "sub" does not match`). Revoke any token or
lease you print while testing (`vault token revoke -accessor <accessor>`).

**4b is complete when** dynamic credentials connect to RDS, revocation drops the
user, the original master password fails, and the `demo-app` service account
logs in with only the `demo-db` policy.

### 4c. External Secrets Operator: dynamic DB credentials in the cluster

Argo CD installs ESO (wave 3) and the `demo` workload (wave 5). The
`VaultDynamicSecret` generator logs in to Vault **as the `demo-app` service
account** and requests `database/creds/demo`. The `ExternalSecret` writes the
lease into Secret `demo-db`, adds `DB_HOST`/`DB_NAME`, and renews it every
30 minutes. The `db-check` Deployment reads the mounted files on every loop, so
it picks up new credentials without restarting.

```
ServiceAccount demo-app ─(token, aud: vault)─▶ VaultDynamicSecret demo-db
   ─▶ Vault jwt-eks role "demo" ─▶ database/creds/demo (new 1h lease)
   ─▶ ExternalSecret demo-db (refresh 30m) ─▶ Secret demo-db ─▶ db-check pod
```

```bash
make status
kubectl -n demo get externalsecret demo-db
```

```
NAME      STORETYPE   STORE   REFRESH INTERVAL   STATUS         READY
demo-db                       30m                SecretSynced   True
```

#### The app connects with its own credentials

```bash
kubectl -n demo get secret demo-db -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n demo logs deploy/db-check --tail=2
```

```
v-jwt-eks-demo-Qx8F2kLm...-1792285123
2026-10-18 09:12:31.42+00|v-jwt-eks-demo-Qx8F2kLm...-1792285123
2026-10-18 09:13:01.48+00|v-jwt-eks-demo-Qx8F2kLm...-1792285123
```

The `v-jwt-eks-demo-` prefix shows the lease came from the app's own identity,
not a person's token.

#### Rotation without a restart

```bash
kubectl -n demo annotate externalsecret demo-db force-sync=$(date +%s) --overwrite
sleep 90
kubectl -n demo logs deploy/db-check --tail=2
```

`current_user` changes to a new `v-jwt-eks-demo-…` user in the same pod. The
kubelet refreshes mounted Secrets within about a minute. Each refresh is a new
lease; older ones expire at their 1h TTL and Vault drops those users:

```bash
vault list sys/leases/lookup/database/creds/demo
```

**4c is complete when** `demo-db` is `SecretSynced`, `db-check` queries RDS as a
`v-jwt-eks-demo-…` user, and a forced refresh switches users in the running pod.

---

## Stage 5: Argo Rollouts canary

_TODO_

## Stage 6: CI/CD and policy

_TODO_

---

## Troubleshooting

### Access and bootstrap

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `kubectl`/Terraform: `dial tcp ...:443: i/o timeout` | Your public IP changed; the endpoint only allows `admin_cidrs` | Compare `curl -s https://checkip.amazonaws.com` with `publicAccessCidrs`; update tfvars, `make apply` |
| `the server has asked for the client to provide credentials` | Your identity has no access entry | `aws sts get-caller-identity` vs `aws eks list-access-entries` |
| `kubectl` points at a deleted cluster after a rebuild | Stale kubeconfig | `make kubeconfig` |
| Plan wants to replace `module.eks.aws_eks_cluster.this` | Provider upgraded by `init -upgrade` | Look for `# forces replacement`; restore `.terraform.lock.hcl` |
| Node group stuck `Still creating`, nodes NotReady, no Cilium pods | Cilium waits on the node group (dependency loop) | Cilium must not `depends_on = [module.eks]`; the node group waits on Cilium via `node_group_wait_for` |
| Node group stuck; instances running but never join | No egress from private subnets | Instance console: `aws ec2 get-console-output --latest --instance-id <id>`; `nodeadm ... DescribeInstances ... context deadline exceeded` means NAT/route |
| Node group `CREATE_FAILED` / `NodeCreationFailure` | Nodes never became Ready | Fix the cause, re-apply; Terraform replaces the node group |
| Interrupted apply left resources tainted | Ctrl+C during create | `terraform untaint <address>` to keep them, or let Terraform replace |
| `Invalid for_each argument` (values known only after apply) | `for_each` keyed by IDs created in the same apply | Pass `map(string)` with static keys (`{ vault = sg-..., eks = sg-... }`) |

### Cilium and nodes

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| Agent logs `Still waiting for Cilium Operator to register CRDs` | Operator not running | `kubectl -n kube-system get pods -l io.cilium/app=operator` |
| Operator `Pending`: `untolerated taint(s)` | `CriticalAddonsOnly` missing from operator tolerations, or set at root level | `helm get values cilium -n kube-system -o json \| jq '{operator: .operator.tolerations, root: .tolerations}'` |
| One operator replica `Pending` | One system node; replicas never share a node | Expected; `operator_replicas = min(2, system nodes)` |
| Operator `CrashLoopBackOff` with credential errors | Pod created before the Pod Identity association | `kubectl -n kube-system rollout restart deploy/cilium-operator` |
| `helm_release.cilium`: `request did not complete within requested timeout` | API server busy (endpoint update) or a stuck webhook | Wait for cluster `ACTIVE`; `helm uninstall cilium -n kube-system`; re-apply |
| Pods fail: `all CIDR ranges are exhausted` | Operator can't allocate ENI IPs, or the node is at its IP limit | Operator logs; system nodes smaller than `t3.large` (a `t3.medium` has ~15 pod IPs) |
| CoreDNS `Pending` / addon `InsufficientNumberOfReplicas` | Nodes still tainted `agent-not-ready` | Fix the Cilium operator first; adding nodes doesn't help |
| Hubble Relay or UI `Pending` | Missing `CriticalAddonsOnly` toleration | `kubectl describe pod -n kube-system -l k8s-app=hubble-relay` |
| `cilium connectivity test`: `Unable to contact Hubble Relay` | No port-forward to Relay | `cilium hubble port-forward &` before the test (tests still run without it) |
| Pods on secondary ENIs lose connectivity | OS network tooling managing Cilium's ENIs | Cilium ENI docs, "Node Configuration" |

### Karpenter

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| EC2NodeClass `READY False` | AMI, subnet or SG selector matched nothing | `kubectl describe ec2nodeclass default`; `karpenter.sh/discovery` tags |
| NodeClaim stuck, `UnauthorizedOperation` | Missing controller permission or tag condition mismatch | `kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter -c controller` |
| `ServiceLinkedRoleCreationNotPermitted` | Account never used Spot | Create the Spot service-linked role (Configuration, step 2) |
| Node launches but never joins | Missing node access entry | `aws eks list-access-entries`; the `*-karpenter-node` role must be `EC2_LINUX` |
| Node never consolidates; event `SpotToSpotConsolidation is disabled` | Feature gate off | `settings.featureGates.spotToSpotConsolidation: true` |
| Node never consolidates; pods still on it | Leftover test pods | `kubectl get pods -A --field-selector spec.nodeName=<node>`; delete `cilium-test-*` namespaces |

### Argo CD and GitOps

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `make check` fails | Placeholder, empty file, wrong path or name | Fix what it lists, then `make push` |
| App sync status `Unknown` | Manifests can't be generated (`kustomization.yaml is empty`, bad path, bad chart version) | `kubectl -n argocd get application <app> -o jsonpath='{.status.conditions}'` |
| `invalid revision: improper constraint` | Chart version missing in `scripts/dev.env` | Set it, `make push` |
| `failed to discover server resources for group version ...` | App synced before its CRDs existed | Retry resolves it; else `make sync APP=<app>` |
| `external-secrets` OutOfSync on CRDs only | cert-controller injects its CA at runtime | `ignoreDifferences` + `RespectIgnoreDifferences=true` (already in the template) |
| `cilium` or `karpenter` OutOfSync right after adoption | Git values differ from the bootstrap values | `make push` |
| `argocd-redis-secret-init` `Pending`; Argo CD install hangs | Hook Job uses `redisSecretInit` scheduling, not `global` | `redisSecretInit.nodeSelector`/`tolerations` in the Argo CD values |
| Argo CD or ESO pods `Pending` | Missing `CriticalAddonsOnly` toleration on a component | `kubectl describe pod`; ESO needs it on controller, webhook and cert-controller |
| `karpenter` app: OCI chart not found | OCI repo not registered | `configs.repositories.karpenter-oci` with `enableOCI: "true"` |

### Vault and External Secrets

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `vault status` connection refused on a node | User data failed | `journalctl -u vault`, `/var/log/cloud-init-output.log` |
| Followers never appear in `list-peers` | Auto-join can't find or reach peers | `journalctl -u vault \| grep -i join`; `vault-cluster` tag; SG 8200/8201 |
| Sealed after reboot | KMS access denied | Instance role KMS permissions; `journalctl -u vault \| grep -i kms` |
| ASG keeps replacing nodes | ELB health checks enabled | `health_check_type = "EC2"` |
| Tunnel accepts connections, then `TLS handshake timeout` | Forwarding to the NLB, which doesn't allow the Vault node SG | `make vault-tunnel` (forwards to the node directly) |
| `x509: "vault.internal" certificate is not trusted` | `VAULT_CACERT` not set in this terminal | `eval "$(make -s vault-env)"` |
| `x509: certificate is valid for ..., not ...` | Client uses a name not in the cert | NLB DNS name, `vault.internal`, `localhost` or `127.0.0.1` |
| `make vault-config`: `connection refused` | Tunnel not running | `make vault-tunnel` in another terminal |
| JWT login: `failed to verify id token` | Vault can't reach the EKS OIDC issuer | NAT egress from infra subnets |
| JWT login: `claim "aud"` / `claim "sub" does not match` | Wrong audience or service account | `--audience vault`; SA `demo/demo-app` |
| Connection recreated after rotation: `password authentication failed` | Stale master password in Terraform | Reset in RDS, update the secret, `-replace` the connection |
| ExternalSecret `SecretSyncedError`: `x509: ... unknown authority` | Bad `caBundle` | `make push` (renders it from Terraform) |
| ExternalSecret `i/o timeout` to Vault | NLB SG doesn't allow the cluster SG | `client_security_groups` includes `eks` |
| `permission denied` on `database/creds/demo` | Policy or role mismatch | `vault policy read demo-db` |

---

## Teardown

```bash
make destroy
```

It asks you to type the cluster name, then:

1. Deletes the root Application with `--cascade=orphan` and stops
   `karpenter-nodes` from re-syncing, so Argo CD can't recreate what Terraform removes.
2. Deletes the NodePools and waits for Karpenter's instances to terminate.
   Instances left behind keep ENIs in the VPC and block the destroy.
3. Runs `terraform destroy` for `infra/envs/dev`.
4. Clears the `dev-vault` state (that Vault no longer exists), so the next
   `make vault-config` starts clean.
5. Lists any leftover Karpenter instances, launch templates and instance profiles
   (`make leftovers`). Delete anything it shows before rebuilding.
