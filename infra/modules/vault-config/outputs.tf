output "jwt_auth_path" {
  description = "JWT auth mount path (SecretStore/generator auth.jwt.path)"
  value       = vault_jwt_auth_backend.eks.path
}

output "database_mount_path" {
  description = "Database secrets engine path"
  value       = vault_mount.database.path
}

output "kv_mount_path" {
  description = "KV v2 mount path"
  value       = vault_mount.kv.path
}

output "workload_roles" {
  description = "Per-workload Vault role and DB creds path"
  value = {
    for k, v in var.workloads : k => {
      jwt_role   = vault_jwt_auth_backend_role.workload[k].role_name
      creds_path = "${vault_mount.database.path}/creds/${k}"
      subject    = "system:serviceaccount:${v.namespace}:${v.service_account}"
    }
  }
}