terraform {
  required_version = ">= 1.5.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "octopusdeploy" {
  address  = var.octopus_url
  api_key  = var.octopus_api_key
  space_id = data.terraform_remote_state.space.outputs.space_id
}

data "terraform_remote_state" "space" {
  backend = "local"
  config = {
    path = "../space/terraform.tfstate"
  }
}

# Both helm + kubernetes default to ~/.kube/config. Override the context if
# you run more than one cluster on this machine.
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = var.kube_context
  }
}

# Outputs from tofu/control-plane/ — environment IDs, etc.
data "terraform_remote_state" "control_plane" {
  backend = "local"
  config = {
    path = "../control-plane/terraform.tfstate"
  }
}

# app-randomquotes/ owns the Previews parent environment. The agent target must
# be scoped to it (see agent_previews_scope.tf). app applies before agent in
# `make apply`, so this state exists on a fresh nuke by the time agent runs.
data "terraform_remote_state" "app" {
  backend = "local"
  config = {
    path = "../app-randomquotes/terraform.tfstate"
  }
}
