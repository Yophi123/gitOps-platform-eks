locals {
  tags = merge({
    "Project" = var.project_name
  }, var.tags)

  helm_values = templatefile("${path.module}/templates/values.yaml.tftpl", {
    cluster_name = var.cluster_name
    queue_name   = aws_sqs_queue.interruption.name
    replicas     = var.replicas
  })

  # EventBridge events Karpenter reacts to (kept short: rule names max 64 chars)
  interruption_events = {
    health    = { source = ["aws.health"], detail-type = ["AWS Health Event"] }
    spot      = { source = ["aws.ec2"], detail-type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance = { source = ["aws.ec2"], detail-type = ["EC2 Instance Rebalance Recommendation"] }
    state     = { source = ["aws.ec2"], detail-type = ["EC2 Instance State-change Notification"] }
    capres    = { source = ["aws.ec2"], detail-type = ["EC2 Capacity Reservation Instance Interruption Warning"] }
  }
}

## Node role (no CNI policy: Cilium's operator owns ENI management)
resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Lets Karpenter-launched nodes join the cluster (replaces aws-auth mapping)
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"

  tags = local.tags
}

## Interruption queue + EventBridge rules
resource "aws_sqs_queue" "interruption" {
  name                      = var.cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = local.tags
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_events

  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode(each.value)

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_events

  rule      = aws_cloudwatch_event_rule.interruption[each.key].name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.interruption.arn
}

## Controller role (Pod Identity)
resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json

  tags = local.tags
}

# Managed policies (6 KB each) rather than inline (10 KB total per role)
resource "aws_iam_policy" "controller" {
  for_each = {
    node-lifecycle   = data.aws_iam_policy_document.node_lifecycle.json
    iam-integration  = data.aws_iam_policy_document.iam_integration.json
    discovery-queue  = data.aws_iam_policy_document.discovery_and_interruption.json
  }

  name   = "${var.cluster_name}-karpenter-${each.key}"
  policy = each.value

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  for_each = aws_iam_policy.controller

  role       = aws_iam_role.controller.name
  policy_arn = each.value.arn
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"
  role_arn        = aws_iam_role.controller.arn

  tags = local.tags
}

## Spot service-linked role (only once per account)
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

## Helm: CRDs as their own release (Helm never upgrades CRDs from crds/)
resource "helm_release" "crd" {
  name       = "karpenter-crd"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.chart_version

  lifecycle {
    ignore_changes = all
  }
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version
  skip_crds  = true

  values = [local.helm_values]

  wait    = true
  timeout = 1200

  lifecycle {
    ignore_changes = all
  }

  depends_on = [
    helm_release.crd,
    aws_iam_role_policy_attachment.controller,
    aws_eks_pod_identity_association.controller,
    aws_eks_access_entry.node,
  ]
}