terraform {
  required_version = ">= 1.10" # S3 native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  # Bucket name comes from backend.hcl (not committed). See README for the first run,
  # where this stack starts on local state and is then moved into the bucket it creates.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "cloudsentinel"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
