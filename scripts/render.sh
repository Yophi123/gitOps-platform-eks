#!/usr/bin/env bash
# Renders the environment-specific GitOps files from scripts/<env>.env and the
# Terraform outputs of infra/envs/<env>. Run it after every apply that can change
# an endpoint (fresh cluster, new Vault NLB, new RDS), then commit and push.
#
#   scripts/render.sh dev      (or: make render)
#
# Writes:
#   gitops/envs/<env>/apps/*.yaml            Argo CD Applications + AppProjects
#   gitops/envs/<env>/values/{cilium,karpenter,argocd}.yaml
#   gitops/platform/karpenter/ec2nodeclass.yaml
#   gitops/apps/demo/{vault-dynamic-secret,external-secret}.yaml  (once Vault/RDS exist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME="${1:-dev}"
ENV_FILE="$ROOT/scripts/$ENV_NAME.env"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
ok()   { echo "  ok   $*"; }

[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TF_DIR="$ROOT/infra/envs/$ENV"
TPL="$ROOT/scripts/templates"
OUT_APPS="$ROOT/gitops/envs/$ENV/apps"
OUT_VALUES="$ROOT/gitops/envs/$ENV/values"

## Inputs from <env>.env
for v in ENV AWS_REGION CLUSTER_NAME GITOPS_REPO_URL GITOPS_REVISION \
         CILIUM_VERSION KARPENTER_VERSION ARGOCD_CHART_VERSION ESO_CHART_VERSION; do
  [ -n "${!v:-}" ] || die "$v is empty in ${ENV_FILE#"$ROOT"/}"
done
case "$GITOPS_REPO_URL" in
  *OWNER/REPO*) die "set GITOPS_REPO_URL in ${ENV_FILE#"$ROOT"/}" ;;
esac
command -v terraform >/dev/null || die "terraform not found"

## Helpers
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

# render <template> <destination>: replaces every @@VAR@@ with the value of $VAR
render() {
  local src="$1" dst="$2" content var
  content="$(cat "$src")"
  for var in $(grep -o '@@[A-Z_]*@@' "$src" | sort -u | tr -d '@' || true); do
    [ -n "${!var:-}" ] || die "$var is empty (needed by ${src#"$ROOT"/})"
    content="${content//@@${var}@@/${!var}}"
  done
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
  ok "${dst#"$ROOT"/}"
}

# Warn when a chart version here differs from terraform.tfvars (bootstrap would
# install one version and Argo CD would immediately switch to the other)
check_tfvar() {
  local key="$1" want="$2" have
  have="$(sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TF_DIR/terraform.tfvars" 2>/dev/null || true)"
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    warn "$key = \"$have\" in terraform.tfvars but $want in $ENV.env"
  fi
}
check_tfvar cilium_version "$CILIUM_VERSION"
check_tfvar karpenter_version "$KARPENTER_VERSION"
check_tfvar argocd_chart_version "$ARGOCD_CHART_VERSION"

## 1. Applications and projects
echo "==> Argo CD Applications ($ENV)"
for t in "$TPL"/apps/*.yaml.tmpl; do
  f="$(basename "$t")"
  render "$t" "$OUT_APPS/${f%.tmpl}"
done

## 2. Helm values handed over from the Terraform bootstrap
echo "==> Helm values"
mkdir -p "$OUT_VALUES"
for chart in cilium karpenter; do
  values="$(tf_out "${chart}_helm_values")"
  [ -n "$values" ] || die "terraform output ${chart}_helm_values is empty: apply infra/envs/$ENV first (make core)"
  printf '%s\n' "$values" > "$OUT_VALUES/$chart.yaml"
  ok "${OUT_VALUES#"$ROOT"/}/$chart.yaml"
done
cp "$ROOT/infra/modules/argocd-bootstrap/templates/argocd-values.yaml" "$OUT_VALUES/argocd.yaml"
ok "${OUT_VALUES#"$ROOT"/}/argocd.yaml"
[ -s "$OUT_VALUES/external-secrets.yaml" ] || warn "${OUT_VALUES#"$ROOT"/}/external-secrets.yaml is missing or empty"

## 3. Karpenter node class (role and discovery tags)
echo "==> Karpenter"
KARPENTER_NODE_ROLE="$(tf_out karpenter_node_role_name)"
[ -n "$KARPENTER_NODE_ROLE" ] || die "terraform output karpenter_node_role_name is empty"
export KARPENTER_NODE_ROLE
render "$TPL/platform/karpenter/ec2nodeclass.yaml.tmpl" "$ROOT/gitops/platform/karpenter/ec2nodeclass.yaml"

## 4. Demo workload: Vault address, CA and RDS host
echo "==> Demo workload"
DEMO_VAULT_ADDR="$(tf_out vault_addr)"
DEMO_DB_HOST="$(tf_out rds_address)"
if [ -z "$DEMO_VAULT_ADDR" ] || [ -z "$DEMO_DB_HOST" ]; then
  warn "Vault/RDS outputs not available yet; gitops/apps/demo left unchanged."
  warn "Run 'make render' again after the full apply."
else
  DEMO_VAULT_CA_BUNDLE="$(tf_out vault_ca_cert_pem | base64 | tr -d '\n')"
  DEMO_DB_NAME="$(tf_out rds_db_name)"
  export DEMO_VAULT_ADDR DEMO_VAULT_CA_BUNDLE DEMO_DB_HOST DEMO_DB_NAME
  for t in "$TPL"/apps-demo/*.yaml.tmpl; do
    f="$(basename "$t")"
    render "$t" "$ROOT/gitops/apps/demo/${f%.tmpl}"
  done
fi

echo
echo "Rendered. Next: make check, then make push."
