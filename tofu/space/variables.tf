variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (local: http://localhost:8090; SaaS: https://<id>.octopus.app)."
}

variable "octopus_api_key" {
  type        = string
  description = "API key minted in Octopus → Profile → My API Keys."
  sensitive   = true
}

variable "space_name" {
  type        = string
  description = "Name of the non-default Space everything in this lab lives inside."
  default     = "IaC Sandbox"
}

variable "space_description" {
  type        = string
  description = "Description set on the Space."
  default     = "Created by tofu/space — destroy nukes everything in it."
}
