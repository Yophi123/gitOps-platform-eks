output "vault_addr" {
  description = "Vault address for in-VPC clients (ESO)"
  value       = "https://${aws_lb.this.dns_name}:8200"
}

output "nlb_dns_name" {
  description = "Internal NLB DNS name"
  value       = aws_lb.this.dns_name
}

output "ca_cert_pem" {
  description = "Vault CA certificate (public; clients use it to verify Vault)"
  value       = tls_self_signed_cert.ca.cert_pem
}

output "security_group_id" {
  description = "Vault node security group (allow it into RDS)"
  value       = aws_security_group.vault.id
}

output "asg_name" {
  description = "Vault Auto Scaling group name"
  value       = aws_autoscaling_group.this.name
}

output "kms_key_arn" {
  description = "Auto-unseal KMS key ARN"
  value       = aws_kms_key.unseal.arn
}

output "cluster_tag" {
  description = "Tag key=value on every Vault node (find instances for SSM)"
  value       = "vault-cluster=${var.name}"
}