terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # bucket is passed at init time (-backend-config); key and locking are fixed here
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "eu-north-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cloudsentinel"
      Stack     = "infra"
      ManagedBy = "terraform"
    }
  }
}
