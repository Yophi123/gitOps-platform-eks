## Argo CD. After the first sync, Argo CD manages itself from Git, so Terraform
## installs once and then ignores changes.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [file("${path.module}/templates/argocd-values.yaml")]

  wait    = true
  timeout = 1200

  lifecycle {
    ignore_changes = all
  }
}

## Root Application (app-of-apps). Terraform keeps owning this one: it's the anchor.
resource "helm_release" "root_app" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [templatefile("${path.module}/templates/root-app.yaml.tftpl", {
    repo_url        = var.repo_url
    target_revision = var.target_revision
    environment     = var.environment
  })]

  depends_on = [helm_release.argocd]
}