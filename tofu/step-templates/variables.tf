variable "octopus_url" {
  type        = string
  description = "Octopus Server URL (http://localhost:8090 locally, https://<id>.octopus.app on SaaS). Sourced from .env via the Makefile."
}

variable "octopus_api_key" {
  type        = string
  description = "Octopus API key. Sourced from .env via the Makefile."
  sensitive   = true
}
