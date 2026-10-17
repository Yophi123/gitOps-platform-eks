## Raft autopilot: clean up peers the ASG replaced
resource "vault_raft_autopilot" "this" {
  cleanup_dead_servers               = true
  dead_server_last_contact_threshold = "10m"
  last_contact_threshold             = "10s"
  server_stabilization_time          = "10s"
  min_quorum                         = var.autopilot_min_quorum
}

## KV v2 for the few static secrets
resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Static secrets (KV v2)"
}

## JWT auth backed by the EKS OIDC issuer (no Kubernetes API calls, no reviewer token)
resource "vault_jwt_auth_backend" "eks" {
  path               = var.jwt_auth_path
  type               = "jwt"
  description        = "EKS service-account tokens"
  oidc_discovery_url = var.eks_oidc_issuer_url
  bound_issuer       = var.eks_oidc_issuer_url
}

## Database secrets engine
resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Dynamic PostgreSQL credentials"
}

resource "vault_database_secret_backend_connection" "app" {
  backend           = vault_mount.database.path
  name              = "app"
  allowed_roles     = ["*"] # access is enforced per workload by policies
  verify_connection = true

  postgresql {
    connection_url          = "postgresql://{{username}}:{{password}}@${local.rds.host}:${local.rds.port}/${local.rds.dbname}?sslmode=require"
    username                = local.rds.username
    password                = local.rds.password
    password_authentication = "scram-sha-256"
  }

  lifecycle {
    # Vault rotates the root password below; re-sending the original would break the connection
    ignore_changes = [postgresql]
  }
}

# One-shot: after this, only Vault knows the RDS master password
resource "vault_generic_endpoint" "rotate_root" {
  count = var.rotate_root_credentials ? 1 : 0

  path           = "${vault_mount.database.path}/rotate-root/${vault_database_secret_backend_connection.app.name}"
  data_json      = jsonencode({})
  disable_read   = true
  disable_delete = true
}

## Per-workload: DB role, policy, JWT login role
resource "vault_database_secret_backend_role" "workload" {
  for_each = var.workloads

  backend     = vault_mount.database.path
  name        = each.key
  db_name     = vault_database_secret_backend_connection.app.name
  default_ttl = each.value.db_default_ttl
  max_ttl     = each.value.db_max_ttl

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT CONNECT ON DATABASE \"${local.rds.dbname}\" TO \"{{name}}\";",
    "GRANT USAGE, CREATE ON SCHEMA public TO \"{{name}}\";",
    "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
    "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";",
  ]

  # Keep data: hand owned objects to the master user before dropping the lease user
  revocation_statements = [
    "REASSIGN OWNED BY \"{{name}}\" TO \"${local.rds.username}\";",
    "DROP OWNED BY \"{{name}}\";",
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}

resource "vault_policy" "workload" {
  for_each = var.workloads

  name   = "${each.key}-db"
  policy = <<-EOT
    # Dynamic DB credentials for ${each.key}
    path "${vault_mount.database.path}/creds/${each.key}" {
      capabilities = ["read"]
    }

    # Static secrets scoped to this workload
    path "${vault_mount.kv.path}/data/${each.key}/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "workload" {
  for_each = var.workloads

  backend         = vault_jwt_auth_backend.eks.path
  role_name       = each.key
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = [var.token_audience]
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"

  token_policies = [vault_policy.workload[each.key].name]
  token_ttl      = 3600
  token_max_ttl  = 14400
}