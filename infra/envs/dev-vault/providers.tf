terraform {
  required_version = ">= 1.10"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket       = "gitops-eks-tfstate-123456"
    key          = "envs/dev-vault/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  profile = "terraform"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# Reached through an SSM port-forward to the internal NLB (see README).
# Token comes from VAULT_TOKEN.
provider "vault" {
  address      = var.vault_addr
  ca_cert_file = "${path.root}/vault-ca.pem"
}