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
}

provider "aws" {
  region = var.aws_region
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