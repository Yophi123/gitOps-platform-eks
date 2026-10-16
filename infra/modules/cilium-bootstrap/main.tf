locals {
  tags = merge({
    "Project" = var.project_name
  }, var.tags)

  helm_values = templatefile("${path.module}/templates/values.yaml.tftpl", {
    cluster_name      = var.cluster_name
    k8s_service_host  = var.k8s_service_host
    vpc_cidr          = var.vpc_cidr
    prefix_delegation = var.enable_prefix_delegation
    hubble_ui         = var.hubble_ui_enabled
    operator_replicas = var.operator_replicas
  })
}

## Cilium operator IAM role (Pod Identity)
resource "aws_iam_role" "operator" {
  name               = "${var.cluster_name}-cilium-operator"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy" "operator" {
  name   = "eni-ipam"
  role   = aws_iam_role.operator.id
  policy = data.aws_iam_policy_document.operator.json
}

resource "aws_eks_pod_identity_association" "operator" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "cilium-operator"
  role_arn        = aws_iam_role.operator.arn

  tags = local.tags
}

## Cilium (one-time bootstrap; Argo CD takes ownership in stage 3).
# Installed before any nodes exist, so there is nothing to wait for:
# pods start as soon as the node group's instances join.
resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "oci://quay.io/cilium/charts"
  chart      = "cilium"
  version    = var.chart_version

  values = [local.helm_values]

  wait = false

  depends_on = [
    aws_iam_role_policy.operator,
    aws_eks_pod_identity_association.operator,
  ]
}
