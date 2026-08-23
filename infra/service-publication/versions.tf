terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # Initialized only with a reviewed runtime backend file. The deployment
  # wrapper rejects local state and requires locking; never add credentials.
  backend "s3" {}
}

provider "cloudflare" {}
