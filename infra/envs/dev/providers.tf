terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = "terraform"

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}
