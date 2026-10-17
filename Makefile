# GitOps Platform on EKS: day-to-day commands.
# Settings come from scripts/$(ENV).env (default: dev).   make help

SHELL := /bin/bash
ENV   ?= dev
include scripts/$(ENV).env

TF        := terraform -chdir=infra/envs/$(ENV)
TF_VAULT  := terraform -chdir=infra/envs/$(ENV)-vault
VAULT_DIR := infra/envs/$(ENV)-vault

# First running Vault node (for SSM sessions and the tunnel)
VAULT_NODE = $$(aws ec2 describe-instances --region $(AWS_REGION) \
  --filters "Name=tag:vault-cluster,Values=$(CLUSTER_NAME)-vault" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

.DEFAULT_GOAL := help
.PHONY: help ami core apply kubeconfig render check push bootstrap status sync \
        vault-shell vault-ca vault-tunnel vault-env vault-config leftovers destroy

help: ## Show this help
	@echo "Targets (ENV=$(ENV), cluster $(CLUSTER_NAME)):"
	@grep -hE '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | \
	  awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

## ── Build and provision ────────────────────────────────────────────────────

ami: ## Build the Vault AMI with Packer
	cd packer/vault && packer init . && packer build .

core: ## Phase 1: VPC, EKS, Cilium, CoreDNS, Karpenter (no Argo CD yet)
	$(TF) init -input=false
	$(TF) apply -target=module.karpenter

apply: ## Full apply of infra/envs/<env> (Argo CD, Vault, RDS, ...)
	$(TF) init -input=false
	$(TF) apply

kubeconfig: ## Point kubectl at this cluster
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)

## ── GitOps ─────────────────────────────────────────────────────────────────

render: ## Render gitops/ (Applications, Helm values, Karpenter, demo) from Terraform outputs
	scripts/render.sh $(ENV)

check: ## Catch placeholders, empty files, broken kustomizations and missing paths
	scripts/check.sh $(ENV)

push: render check ## Render, check, then commit and push gitops/ if anything changed
	git add gitops
	@if git diff --cached --quiet; then echo "gitops/ unchanged; nothing to push"; \
	else git commit -m "$(ENV): render gitops" && git push; fi

bootstrap: ## From scratch: core → push → full apply → push (Vault init/config follow)
	$(MAKE) core
	$(MAKE) kubeconfig
	$(MAKE) push
	$(MAKE) apply
	$(MAKE) push
	@echo
	@echo "Next: initialize Vault once (make vault-shell, then 'vault operator init'),"
	@echo "      then make vault-tunnel (own terminal) and make vault-config."

status: ## Argo CD Applications at a glance
	kubectl -n argocd get applications

sync: ## Force a sync of one Application: make sync APP=demo
	@[ -n "$(APP)" ] || { echo "usage: make sync APP=<name>"; exit 1; }
	kubectl -n argocd annotate application $(APP) argocd.argoproj.io/refresh=hard --overwrite
	kubectl -n argocd patch application $(APP) --type=merge -p '{"operation":{"sync":{}}}'

## ── Vault ──────────────────────────────────────────────────────────────────

vault-shell: ## Shell on a Vault node through SSM (vault CLI is preconfigured there)
	aws ssm start-session --region $(AWS_REGION) --target $(VAULT_NODE)

vault-ca: ## Write the Vault CA to infra/envs/<env>-vault/vault-ca.pem
	$(TF) output -raw vault_ca_cert_pem > $(VAULT_DIR)/vault-ca.pem
	@echo "wrote $(VAULT_DIR)/vault-ca.pem"

vault-tunnel: vault-ca ## Forward localhost:8200 to a Vault node (keep it running in its own terminal)
	aws ssm start-session --region $(AWS_REGION) --target $(VAULT_NODE) \
	  --document-name AWS-StartPortForwardingSession \
	  --parameters "portNumber=8200,localPortNumber=8200"

vault-env: ## Print Vault CLI env vars (use with eval, see README)
	@echo "export VAULT_ADDR=https://localhost:8200"
	@echo "export VAULT_CACERT=$(CURDIR)/$(VAULT_DIR)/vault-ca.pem"

vault-config: ## Apply Vault's configuration (needs the tunnel and VAULT_TOKEN)
	@[ -n "$$VAULT_TOKEN" ] || { echo "export VAULT_TOKEN first (admin or root token)"; exit 1; }
	@[ -s $(VAULT_DIR)/vault-ca.pem ] || $(MAKE) vault-ca
	$(TF_VAULT) init -input=false
	$(TF_VAULT) apply

## ── Teardown ───────────────────────────────────────────────────────────────

leftovers: ## List Karpenter instances, launch templates and instance profiles left behind
	@echo "Instances:";         aws ec2 describe-instances --region $(AWS_REGION) \
	  --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
	  --query 'Reservations[].Instances[].InstanceId' --output text
	@echo "Launch templates:";  aws ec2 describe-launch-templates --region $(AWS_REGION) \
	  --filters "Name=tag:karpenter.k8s.aws/cluster,Values=$(CLUSTER_NAME)" \
	  --query 'LaunchTemplates[].LaunchTemplateName' --output text
	@echo "Instance profiles:"; aws iam list-instance-profiles \
	  --query "InstanceProfiles[?contains(InstanceProfileName, '$(CLUSTER_NAME)')].InstanceProfileName" --output text

destroy: ## Stop Argo CD, drain Karpenter nodes, terraform destroy, reset Vault config state
	@read -r -p "Destroy $(CLUSTER_NAME)? Type the cluster name: " ans && [ "$$ans" = "$(CLUSTER_NAME)" ]
	-kubectl -n argocd delete application root --cascade=orphan --request-timeout=30s
	-kubectl -n argocd patch application karpenter-nodes --type=merge -p '{"spec":{"syncPolicy":null}}' --request-timeout=30s
	-kubectl delete nodepool --all --request-timeout=60s
	-kubectl wait --for=delete nodeclaims --all --timeout=10m
	$(TF) destroy
	@# Vault's config died with the cluster; forget it so the next vault-config starts clean
	@set -f; res="$$($(TF_VAULT) state list 2>/dev/null)"; \
	  if [ -n "$$res" ]; then $(TF_VAULT) state rm $$res; fi
	$(MAKE) leftovers
