variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (e.g. http://localhost:8090)."
}

variable "octopus_api_key" {
  type        = string
  description = "API key minted in Octopus → Profile → My API Keys."
  sensitive   = true
}

variable "octopus_space" {
  type        = string
  description = "Space ID (not name). Default install ships with Spaces-1."
  default     = "Spaces-1"
}

variable "github_pat" {
  type        = string
  description = "GitHub PAT (classic, repo scope). Same one cp uses for the CaC credential."
  sensitive   = true
}

variable "github_username" {
  type        = string
  description = "Username paired with the PAT. Anything works for GitHub PAT auth — the token carries the identity."
  default     = "vlussenburg"
}

variable "ph_repo_url" {
  type        = string
  description = "HTTPS URL of the Git repo Platform Hub reads policies from."
}

variable "ph_branch" {
  type        = string
  description = "Default branch Platform Hub reads from."
  default     = "main"
}

variable "ph_base_path" {
  type        = string
  description = "Path inside the repo where Platform Hub policy YAML lives."
  default     = ".octopus"
}
