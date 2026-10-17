#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait || true

echo "==> [1/4] Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y \
    curl \
    wget \
    gpg \
    jq \
    lsb-release \
    ca-certificates \
    unzip

echo "==> Installing AWS CLI"
# AWS CLI v2, used by user data to read the TLS material from SSM.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

echo "==> [2/4] Installing HashiCorp repo..."
wget -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/hashicorp.list

echo "==> [3/4] Installing Vault..."
apt-get update -y
if [ -n "${VAULT_VERSION:-}" ]; then
  apt-get install -y "vault=${VAULT_VERSION}-1"
else
  apt-get install -y vault
fi
vault version

# User data writes the config, TLS material and Raft directory at boot
systemctl disable --now vault
rm -f /etc/vault.d/vault.hcl
rm -rf /opt/vault/tls/*

echo "==> [4/4] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"