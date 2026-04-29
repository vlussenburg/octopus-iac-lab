terraform {
  required_version = ">= 1.5.0"

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
  space_id = var.octopus_space
}

# Reads outputs from the control-plane stack — environments, lifecycle,
# project group, git credential. Both stacks use the local backend, so
# this is just a relative file path.
data "terraform_remote_state" "control_plane" {
  backend = "local"
  config = {
    path = "../control-plane/terraform.tfstate"
  }
}
