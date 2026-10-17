#!/usr/bin/env bash
# Catches the mistakes that broke syncs before: leftover placeholders, empty
# files, kustomizations that don't build, Applications pointing at missing paths.
#
#   scripts/check.sh dev      (or: make check)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_NAME="${1:-dev}"
cd "$ROOT" || exit 1

fail=0
bad()  { echo "  FAIL $*"; fail=1; }
good() { echo "  ok   $*"; }

echo "==> Placeholders"
if grep -rnE '@@[A-Z_]+@@|OWNER/REPO|<x\.y\.z>|CLUSTER_NAME-|VAULT_CA_BUNDLE|DB_HOST_VALUE' gitops/; then
  bad "placeholders left in gitops/ (run make render)"
else
  good "none"
fi

echo "==> Empty files"
empty=0
while IFS= read -r f; do
  [ -s "$f" ] || { bad "$f is empty"; empty=1; }
done < <(find gitops -type f \( -name '*.yaml' -o -name '*.yml' \))
[ "$empty" -eq 0 ] && good "none"

echo "==> Kustomizations build"
if command -v kubectl >/dev/null; then
  for d in gitops/platform/karpenter gitops/apps/demo; do
    if out="$(kubectl kustomize "$d" 2>&1)"; then
      good "$d ($(grep -c '^kind:' <<<"$out") objects)"
    else
      bad "$d"; echo "$out" | sed 's/^/       /'
    fi
  done
else
  echo "  skip kubectl not installed"
fi

echo "==> Application paths and value files exist"
for app in gitops/envs/"$ENV_NAME"/apps/*.yaml; do
  for p in $(sed -nE 's/^[[:space:]]+path:[[:space:]]+(gitops\/[^[:space:]]+).*/\1/p' "$app"); do
    [ -d "$p" ] || bad "$(basename "$app"): path $p does not exist"
  done
  for v in $(sed -nE 's/.*\$values\/(gitops\/[^[:space:]]+).*/\1/p' "$app"); do
    [ -s "$v" ] || bad "$(basename "$app"): values file $v missing or empty"
  done
done
[ "$fail" -eq 0 ] && good "all referenced paths exist"

echo
if [ "$fail" -ne 0 ]; then
  echo "check FAILED"
  exit 1
fi
echo "check passed"
