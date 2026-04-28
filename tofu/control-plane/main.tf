terraform {
  required_version = ">= 1.5.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeployLabs/octopusdeploy"
      version = "~> 0.43"
    }
  }
}

provider "octopusdeploy" {
  address  = var.octopus_url
  api_key  = var.octopus_api_key
  space_id = var.octopus_space
}
