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
  space_id = data.terraform_remote_state.space.outputs.space_id
}

# Reads the Space ID from tofu/space/. Apply order is enforced by the Makefile:
# space → cp → ph → app → agent.
data "terraform_remote_state" "space" {
  backend = "local"
  config = {
    path = "../space/terraform.tfstate"
  }
}
