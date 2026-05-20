terraform {
  required_version = ">= 1.5.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.12"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Library step templates (custom action templates) live at
# /api/Spaces-{n}/actiontemplates — they are NOT a Platform Hub artifact
# and CANNOT be hosted in the PH Git repo. They're per-space resources.
#
# The octopusdeploy provider v1.12 has no resource for action templates,
# so the stack drives the REST API via a null_resource + curl (same
# pattern as tofu/servicenow/integration.tf for the ITSM connection).
#
# Re-runs are idempotent: the script GETs by name, then PUTs to update or
# POSTs to create.

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
