terraform {
  required_version = ">= 1.5.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.13"
    }
  }
}

# Library step templates (custom action templates) live at
# /api/Spaces-{n}/actiontemplates — they are NOT a Platform Hub artifact
# and CANNOT be hosted in the PH Git repo. They're per-space resources
# stored in the Octopus DB.
#
# Provider v1.13 ships `octopusdeploy_step_template` (typed resource);
# v1.12 had nothing, so the prior shape here was a null_resource + curl.

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
