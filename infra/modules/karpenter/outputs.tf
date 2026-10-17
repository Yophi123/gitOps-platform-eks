output "node_role_name" {
  description = "Node IAM role name (EC2NodeClass spec.role)"
  value       = aws_iam_role.node.name
}

output "node_role_arn" {
  description = "Node IAM role ARN"
  value       = aws_iam_role.node.arn
}

output "controller_role_arn" {
  description = "Controller IAM role ARN (Pod Identity)"
  value       = aws_iam_role.controller.arn
}

output "interruption_queue_name" {
  description = "SQS interruption queue name (settings.interruptionQueue)"
  value       = aws_sqs_queue.interruption.name
}

output "release_name" {
  description = "Karpenter Helm release name"
  value       = helm_release.karpenter.name
}

output "chart_version" {
  description = "Installed Karpenter chart version"
  value       = helm_release.karpenter.version
}

output "helm_values" {
  description = "Rendered Helm values; copy to gitops/platform/karpenter/values.yaml for Argo CD adoption"
  value       = local.helm_values
}