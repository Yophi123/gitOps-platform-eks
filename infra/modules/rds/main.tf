locals {
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

resource "random_password" "master" {
  length  = 32
  special = false # avoids quoting issues in connection URLs
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = local.tags
}

resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "Postgres from Vault and the cluster"
  vpc_id      = var.vpc_id
  tags        = merge({ "Name" = "${var.name}-db" }, local.tags)
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_groups

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Postgres from ${each.key}"
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = true # dev; set false and a snapshot name for prod

  tags = local.tags

  lifecycle {
    # Vault rotates the master password in stage 4b; Terraform must not reset it
    ignore_changes = [password]
  }
}

## Initial master credentials, read once by infra/envs/<env>-vault, then rotated by Vault
resource "aws_secretsmanager_secret" "master" {
  name                    = "${var.name}/master"
  description             = "Initial RDS master credentials (superseded once Vault rotates root)"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
  })
}