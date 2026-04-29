# The Space stack is the root of every other stack — it creates the non-default
# Space everything else lives inside. `tofu destroy` here is the kill switch:
# Octopus deletes the Space and cascades to every project / env / lifecycle /
# credential / target inside it, on both local and SaaS.
#
# Provider is bound to the system Space (Spaces-1) because we need permission
# to *create* a Space. Once the Space exists, downstream stacks bind their
# provider to its ID via terraform_remote_state.
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
  space_id = "Spaces-1"
}
