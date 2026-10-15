locals {
  region   = data.aws_region.current.region
  az_count = 3
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # Each AZ owns a contiguous block of tiers: index = az * tier_stride + tier offset.
  # /16 + newbits 4 = 16 x /20; 3 AZs x 5 tiers = 15 used, 1 spare.
  tier_offset = {
    reserved = 0
    db       = 1
    app      = 2
    web      = 3
    infra    = 4
  }
  tier_stride = length(local.tier_offset)

  ipv4_subnet = {
    for tier, offset in local.tier_offset : tier => [
      for i in range(local.az_count) :
      # cidr-mask + 4 (16 + 4), 
      cidrsubnet(var.vpc_cidr, 4, i * local.tier_stride + offset)
    ]
  }

  # IPv6 /64s mirror the IPv4 layout inside the VPC /56.
  ipv6_subnet = {
    for tier, offset in local.tier_offset : tier => [
      for i in range(local.az_count) :
      var.ipv6_enabled ? cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, i * local.tier_stride + offset) : null
    ]
  }

  private_zone_name = var.private_zone_name == null ? null : trimsuffix(var.private_zone_name, ".")
  create_zone       = var.enable_private_zone
  create_dhcp       = var.enable_dhcp_options && var.enable_private_zone

  compute_domain = local.region == "us-east-1" ? "ec2.internal" : "${local.region}.compute.internal"
}

## VPC
resource "aws_vpc" "main" {
  cidr_block                       = var.vpc_cidr
  enable_dns_hostnames             = var.enable_dns_hostnames
  enable_dns_support               = var.enable_dns_support
  assign_generated_ipv6_cidr_block = var.ipv6_enabled

  tags = merge({
    "Name"    = "${var.project_name}-vpc"
    "Project" = var.project_name
  }, var.tags)
}

## DHCP Options (only with a private zone; off by default for EKS)
resource "aws_vpc_dhcp_options" "this" {
  count               = local.create_dhcp ? 1 : 0
  domain_name         = "${local.private_zone_name} ${local.compute_domain}"
  domain_name_servers = ["AmazonProvidedDNS"]

  tags = merge({
    "Name"    = "${var.project_name}-dhcp-options"
    "Project" = var.project_name
  }, var.tags)
}

resource "aws_vpc_dhcp_options_association" "this" {
  count           = local.create_dhcp ? 1 : 0
  vpc_id          = aws_vpc.main.id
  dhcp_options_id = aws_vpc_dhcp_options.this[0].id
}

## Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge({
    "Name"    = "${var.project_name}-igw"
    "Project" = var.project_name
  }, var.tags)
}

## Egress-only Gateway (IPv6)
resource "aws_egress_only_internet_gateway" "eigw" {
  count  = var.ipv6_enabled ? 1 : 0
  vpc_id = aws_vpc.main.id

  tags = merge({
    "Name"    = "${var.project_name}-egress-igw"
    "Project" = var.project_name
  }, var.tags)
}

## Regional NAT Gateway (auto mode: expands into AZs as ENIs appear)
resource "aws_nat_gateway" "nat_gw" {
  vpc_id            = aws_vpc.main.id
  connectivity_type = "public"
  availability_mode = "regional"

  depends_on = [aws_internet_gateway.igw]

  tags = merge({
    "Name"    = "${var.project_name}-natgw"
    "Project" = var.project_name
  }, var.tags)
}

## Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  dynamic "route" {
    for_each = var.ipv6_enabled ? [1] : []
    content {
      ipv6_cidr_block = "::/0"
      gateway_id      = aws_internet_gateway.igw.id
    }
  }

  tags = merge({
    "Name"    = "${var.project_name}-public-rt"
    "Project" = var.project_name
  }, var.tags)
}

## Private Route Table (app + infra)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge({
    "Name"    = "${var.project_name}-private-rt"
    "Project" = var.project_name
  }, var.tags)
}

resource "aws_route" "private_internet_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gw.id
}

resource "aws_route" "private_internet_access_ipv6" {
  count                       = var.ipv6_enabled ? 1 : 0
  route_table_id              = aws_route_table.private.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw[0].id
}

## Database Route Table (no internet route)
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = merge({
    "Name"    = "${var.project_name}-database-rt"
    "Project" = var.project_name
  }, var.tags)
}

## Web/Public Subnets (internet-facing ALBs)
resource "aws_subnet" "web" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.ipv4_subnet.web[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = var.map_public_ip_on_launch

  # Internet-routable over IPv6, so only hand addresses to things that ask.
  ipv6_cidr_block                 = local.ipv6_subnet.web[count.index]
  assign_ipv6_address_on_creation = false

  tags = merge({
    "Name"                   = "${var.project_name}-web-${substr(local.azs[count.index], -1, 1)}"
    "Project"                = var.project_name
    "Tier"                   = "web"
    "kubernetes.io/role/elb" = "1"
  }, var.tags)
}

## App Subnets (Karpenter nodes + Cilium pod IPs, internal LBs)
resource "aws_subnet" "app" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.ipv4_subnet.app[count.index]
  availability_zone = local.azs[count.index]

  ipv6_cidr_block                 = local.ipv6_subnet.app[count.index]
  assign_ipv6_address_on_creation = var.ipv6_enabled

  tags = merge({
    "Name"                            = "${var.project_name}-app-${substr(local.azs[count.index], -1, 1)}"
    "Project"                         = var.project_name
    "Tier"                            = "app"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }, var.tags)
}

## Infra Subnets (EKS control-plane ENIs, system node group)
resource "aws_subnet" "infra" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.ipv4_subnet.infra[count.index]
  availability_zone = local.azs[count.index]

  ipv6_cidr_block                 = local.ipv6_subnet.infra[count.index]
  assign_ipv6_address_on_creation = var.ipv6_enabled

  tags = merge({
    "Name"    = "${var.project_name}-infra-${substr(local.azs[count.index], -1, 1)}"
    "Project" = var.project_name
    "Tier"    = "infra"
  }, var.tags)
}

## Database Subnets (isolated)
resource "aws_subnet" "db" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.ipv4_subnet.db[count.index]
  availability_zone = local.azs[count.index]

  ipv6_cidr_block                 = local.ipv6_subnet.db[count.index]
  assign_ipv6_address_on_creation = var.ipv6_enabled

  tags = merge({
    "Name"    = "${var.project_name}-db-${substr(local.azs[count.index], -1, 1)}"
    "Project" = var.project_name
    "Tier"    = "db"
  }, var.tags)
}

## Route Table Associations
resource "aws_route_table_association" "web" {
  count          = local.az_count
  subnet_id      = aws_subnet.web[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "infra" {
  count          = local.az_count
  subnet_id      = aws_subnet.infra[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  count          = local.az_count
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

## Private Hosted Zone (optional)
resource "aws_route53_zone" "private" {
  count         = local.create_zone ? 1 : 0
  name          = local.private_zone_name
  comment       = "Private zone for ${var.project_name}"
  force_destroy = var.records_force_destroy

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge({
    "Project" = var.project_name
  }, var.tags)

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "this" {
  for_each = local.create_zone ? var.records : {}
  zone_id  = aws_route53_zone.private[0].zone_id
  name     = each.value.name == "" ? local.private_zone_name : "${each.value.name}.${local.private_zone_name}"
  type     = each.value.type

  ttl     = each.value.alias == null ? each.value.ttl : null
  records = each.value.alias == null ? each.value.records : null

  dynamic "alias" {
    for_each = each.value.alias == null ? [] : [each.value.alias]
    content {
      name                   = alias.value.dns_name
      zone_id                = alias.value.zone_id
      evaluate_target_health = alias.value.evaluate_target_health
    }
  }
}

## S3 Gateway Endpoint (free; ECR image layers come from S3)
resource "aws_vpc_endpoint" "s3" {
  count             = var.enable_s3_endpoint ? 1 : 0
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Public subnets already reach S3 through the IGW at no NAT cost.
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.db.id,
  ]

  tags = merge({
    "Name"    = "${var.project_name}-s3-endpoint"
    "Project" = var.project_name
  }, var.tags)
}
