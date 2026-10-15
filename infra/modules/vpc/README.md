# vpc

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![AWS Provider](https://img.shields.io/badge/AWS%20provider-%3E%3D%206.0-FF9900)
![IPv6](https://img.shields.io/badge/IPv6-optional-0A7BBB)
![Karpenter](https://img.shields.io/badge/Karpenter-discovery%20tagged-2E8B57)
![infra-ci](https://github.com/Yophi123/gitOps-platform-eks/actions/workflows/infra-ci.yml/badge.svg)

Three-AZ VPC for the GitOps EKS platform. It uses one /16 split into /20s across
five tiers per AZ, with a regional NAT gateway and an isolated database tier.

## Design

- **Tiers per AZ**: `reserved`, `db`, `app`, `web`, `infra`. Each is a /20, and
  each AZ owns a contiguous block of tiers.
- **app**: Karpenter nodes and Cilium ENI-mode pod IPs. Tagged
  `karpenter.sh/discovery` and `kubernetes.io/role/internal-elb`.
- **infra**: EKS control-plane ENIs and the system node group.
- **web**: internet-facing load balancers only (`kubernetes.io/role/elb`). No
  public IPs on launch.
- **db**: no internet route.
- **Regional NAT gateway**: a single resource that expands into AZs as ENIs
  appear.
- **S3 gateway endpoint**: on the private and db route tables. It's free, and it
  keeps ECR image-layer pulls off the NAT gateway.
- **Default security group**: locked down with all rules removed.
- **Private hosted zone and DHCP options**: optional and off by default. CoreDNS
  handles in-cluster discovery, and a DHCP search domain would multiply pod DNS
  lookups.

### Subnet layout (`10.16.0.0/16`)

| Tier     | AZ a           | AZ b            | AZ c            |
|----------|----------------|-----------------|-----------------|
| reserved | 10.16.0.0/20   | 10.16.80.0/20   | 10.16.160.0/20  |
| db       | 10.16.16.0/20  | 10.16.96.0/20   | 10.16.176.0/20  |
| app      | 10.16.32.0/20  | 10.16.112.0/20  | 10.16.192.0/20  |
| web      | 10.16.48.0/20  | 10.16.128.0/20  | 10.16.208.0/20  |
| infra    | 10.16.64.0/20  | 10.16.144.0/20  | 10.16.224.0/20  |
| spare    | 10.16.240.0/20 |                 |                 |

## Usage

Called from the environment root (`envs/dev/main.tf`):

```hcl
locals {
  project_name = "gitops-eks"
  environment  = "dev"
  cluster_name = "${local.project_name}-${local.environment}"

  tags = {
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name = local.project_name
  cluster_name = local.cluster_name # must match module.eks cluster_name
  vpc_cidr     = "10.16.0.0/16"     # prod: 10.17.0.0/16 (no overlap)

  enable_s3_endpoint = true
  ipv6_enabled       = false

  tags = local.tags
}
```

Downstream modules consume it like this:

```hcl
module "eks" {
  # ...
  control_plane_subnet_ids = module.vpc.infra_subnet_ids
  node_subnet_ids          = module.vpc.infra_subnet_ids
}

# Cilium native routing:  ipv4NativeRoutingCIDR = module.vpc.vpc_cidr
# RDS subnet group:       subnet_ids            = module.vpc.db_subnet_ids
# Vault (EC2):            subnet_id             = module.vpc.infra_subnet_ids[0]
```

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| project_name | Project name for all associated resources | `string` | n/a |
| cluster_name | EKS cluster name for the `karpenter.sh/discovery` tag | `string` | n/a |
| vpc_cidr | VPC CIDR (must be a /16) | `string` | `"10.16.0.0/16"` |
| enable_private_zone | Create a Route 53 private hosted zone | `bool` | `false` |
| private_zone_name | Fully qualified private zone name (no `.local`) | `string` | `null` |
| records | Private zone records (alias or records + ttl) | `map(object)` | `{}` |
| records_force_destroy | Delete all records when destroying the zone | `bool` | `false` |
| enable_dns_hostnames | VPC DNS hostnames | `bool` | `true` |
| enable_dns_support | VPC DNS support | `bool` | `true` |
| enable_dhcp_options | Add the private zone to the DHCP search path | `bool` | `false` |
| map_public_ip_on_launch | Auto-assign public IPv4 in the web tier | `bool` | `false` |
| ipv6_enabled | Amazon-provided /56 and a /64 per subnet | `bool` | `false` |
| enable_s3_endpoint | S3 gateway endpoint on private and db route tables | `bool` | `true` |
| tags | Tags merged onto all resources | `map(string)` | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| vpc_id | ID of the VPC |
| vpc_cidr | CIDR block of the VPC |
| azs | AZs used by the subnets |
| web_subnet_ids | Public subnet IDs (internet-facing ALBs) |
| app_subnet_ids | App subnet IDs (Karpenter nodes, Cilium pod IPs) |
| infra_subnet_ids | Infra subnet IDs (control-plane ENIs, system nodes) |
| db_subnet_ids | Isolated database subnet IDs |
| app_subnet_cidrs | App subnet CIDRs |
| public_route_table_id | Public route table ID |
| private_route_table_id | Private route table ID (app + infra) |
| db_route_table_id | Database route table ID |
| nat_gateway_id | Regional NAT gateway ID |
| private_zone_id | Private hosted zone ID, or null |
<!-- END_TF_DOCS -->