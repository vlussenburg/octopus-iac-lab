terraform {
  required_version = ">= 1.6"
  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.12"
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

data "terraform_remote_state" "control_plane" {
  backend = "local"
  config = {
    path = "../control-plane/terraform.tfstate"
  }
}

locals {
  space_id          = data.terraform_remote_state.space.outputs.space_id
  production_env_id = data.terraform_remote_state.control_plane.outputs.environment_ids.production
}
