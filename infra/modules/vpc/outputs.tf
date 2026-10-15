output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "azs" {
  description = "AZs used by the subnets"
  value       = local.azs
}

output "web_subnet_ids" {
  description = "Public subnet IDs (internet-facing ALBs)"
  value       = aws_subnet.web[*].id
}

output "app_subnet_ids" {
  description = "App subnet IDs (Karpenter nodes, Cilium pod IPs)"
  value       = aws_subnet.app[*].id
}

output "infra_subnet_ids" {
  description = "Infra subnet IDs (EKS control-plane ENIs, system node group)"
  value       = aws_subnet.infra[*].id
}

output "db_subnet_ids" {
  description = "Isolated database subnet IDs"
  value       = aws_subnet.db[*].id
}

output "app_subnet_cidrs" {
  description = "App subnet CIDRs"
  value       = aws_subnet.app[*].cidr_block
}

output "public_route_table_id" {
  description = "Public route table ID"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "Private route table ID (app + infra)"
  value       = aws_route_table.private.id
}

output "db_route_table_id" {
  description = "Database route table ID"
  value       = aws_route_table.db.id
}

output "nat_gateway_id" {
  description = "ID of the regional NAT gateway"
  value       = aws_nat_gateway.nat_gw.id
}

output "private_zone_id" {
  description = "Private hosted zone ID, or null when disabled"
  value       = try(aws_route53_zone.private[0].zone_id, null)
}