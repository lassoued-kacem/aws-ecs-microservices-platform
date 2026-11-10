terraform {
  # >= 1.10 for S3 native state locking (use_lockfile), used by the other layers.
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Layer     = "foundation"
    }
  }
}

# Partial backend: bucket and region are passed at init time
# (-backend-config=bucket=... -backend-config=region=...) so nothing
# account-specific is committed.
terraform {
  backend "s3" {
    key          = "foundation/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
