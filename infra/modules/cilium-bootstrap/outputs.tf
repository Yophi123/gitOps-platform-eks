output "release_name" {
  description = "Helm release name (Argo CD's Application must use the same name)"
  value       = helm_release.cilium.name
}

output "release_namespace" {
  description = "Helm release namespace"
  value       = helm_release.cilium.namespace
}

output "chart_version" {
  description = "Installed Cilium chart version"
  value       = helm_release.cilium.version
}

output "operator_role_arn" {
  description = "IAM role ARN used by the Cilium operator via Pod Identity"
  value       = aws_iam_role.operator.arn
}

output "helm_values" {
  description = "Rendered Helm values; copy to gitops/platform/cilium/values.yaml for Argo CD adoption"
  value       = local.helm_values
}