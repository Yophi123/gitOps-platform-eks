data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = var.rds_master_secret_arn
}

locals {
  rds = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)
}