terraform {
  required_providers {
    aws = {
          source  = "hashicorp/aws"
          version = "~> 5.92.0"
    }
    helm = {
        source  = "hashicorp/helm"
        version = "~> 2.17.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19.0"
    }
    kubernetes = {
        source = "hashicorp/kubernetes"
        version = "~> 2.33.0"
    }
    random = {
        source = "hashicorp/random"
        version = "~> 3.6.3"
    }
    null = {
        source = "hashicorp/null"
        version = "~> 3.2.3"
    }
  }

  required_version = ">= 1.2.0"
}

module "root" {
  source = "../"
  region = var.region
  reducto_helm_repo_username = var.reducto_helm_repo_username
  reducto_helm_repo_password = var.reducto_helm_repo_password
  reducto_host = var.reducto_host
  openai_api_key = var.openai_api_key
}