variable "environment" {
  type        = string
  description = "Environment name; the root app watches gitops/envs/<environment>/apps"
}

variable "repo_url" {
  type        = string
  description = "Git repository URL Argo CD syncs from (https://github.com/OWNER/REPO.git)"
}

variable "target_revision" {
  type        = string
  description = "Branch, tag or commit for the root app"
  default     = "main"
}

variable "argocd_chart_version" {
  type        = string
  description = "argo-cd chart version (helm search repo argo/argo-cd)"
}

variable "argocd_apps_chart_version" {
  type        = string
  description = "argocd-apps chart version (helm search repo argo/argocd-apps)"
}