output "namespace" {
  description = "Argo CD namespace"
  value       = helm_release.argocd.namespace
}

output "root_app_path" {
  description = "Repo path the root Application watches"
  value       = "gitops/envs/${var.environment}/apps"
}

output "admin_password_command" {
  description = "Command to read the initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}