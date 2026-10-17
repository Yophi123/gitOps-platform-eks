# argocd-bootstrap

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.9-7B42BC?logo=terraform&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo%20CD-3.x-EF7B4D?logo=argo&logoColor=white)
![Pattern](https://img.shields.io/badge/pattern-app--of--apps-informational)

Installs Argo CD and a single root Application. Everything else, including
Argo CD itself, is reconciled from `gitops/envs/<env>/apps`.

## Design

- **Install once, then hand over.** `ignore_changes = all` on the Argo CD release:
  after the first sync, the `argocd` Application in Git manages Argo CD.
- **Root app stays in Terraform.** It's the one object that points Argo CD at Git.
- **System nodes.** `global.nodeSelector` and `global.tolerations` pin every
  component to the system node group.
- **App health check** so sync waves wait for child Applications.
- **OCI Helm repo** registered for Karpenter's charts on public ECR.
- Dex and notifications are off.

## Usage

```hcl
module "argocd_bootstrap" {
  source = "../../modules/argocd-bootstrap"

  environment               = var.environment
  repo_url                  = var.gitops_repo_url
  argocd_chart_version      = var.argocd_chart_version
  argocd_apps_chart_version = var.argocd_apps_chart_version

  depends_on = [module.karpenter]
}
```

Values and Applications must be pushed to Git **before** applying; the root
app syncs immediately.

## Outputs

| Name | Description |
|------|-------------|
| namespace | Argo CD namespace |
| root_app_path | Repo path the root Application watches |
| admin_password_command | Reads the initial admin password |