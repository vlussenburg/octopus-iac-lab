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

# Platform Hub endpoints (/api/platformhub/*) are server-wide, not Space-scoped,
# so the provider's space_id is technically a no-op for the resources here.
# We still bind it for consistency and so the provider's connectivity check
# uses a Space we own.
data "terraform_remote_state" "space" {
  backend = "local"
  config = {
    path = "../space/terraform.tfstate"
  }
}
