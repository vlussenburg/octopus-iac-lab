variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (e.g. http://localhost:8090)."
}

variable "octopus_api_key" {
  type        = string
  description = "API key minted in Octopus → Profile → My API Keys."
  sensitive   = true
}

variable "cac_repo_url" {
  type        = string
  description = "HTTPS URL of the Git repo Octopus pulls/pushes CaC from."
}

variable "cac_branch" {
  type        = string
  description = "Default branch Octopus uses for CaC."
  default     = "main"
}

variable "cac_base_path" {
  type        = string
  description = "Path inside the repo where Octopus stores OCL files. Octopus enforces .octopus."
  default     = ".octopus"
}
