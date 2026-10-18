output "address" {
  description = "RDS hostname"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Application database name"
  value       = aws_db_instance.this.db_name
}

output "master_secret_arn" {
  description = "Secrets Manager ARN with the initial master credentials"
  value       = aws_secretsmanager_secret.master.arn
}

output "security_group_id" {
  description = "Database security group"
  value       = aws_security_group.this.id
}