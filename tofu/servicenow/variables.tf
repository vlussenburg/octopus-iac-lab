variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server."
}

variable "octopus_api_key" {
  type        = string
  description = "Octopus API key with admin rights — needed for /api/configuration/servicenow-integration."
  sensitive   = true
}

variable "servicenow_url" {
  type        = string
  description = "ServiceNow PDI instance base URL (e.g. https://dev123456.service-now.com)."
}

variable "servicenow_username" {
  type        = string
  description = "ServiceNow PDI admin username for basic auth."
}

variable "servicenow_password" {
  type        = string
  description = "ServiceNow PDI admin password — paired with the OAuth client for the password-grant flow Octopus uses."
  sensitive   = true
}

variable "servicenow_oauth_client_id" {
  type        = string
  description = "OAuth client ID from ServiceNow → System OAuth → Application Registry → 'Create an OAuth API endpoint for external clients'. No redirect URI needed — Octopus uses the password grant."
}

variable "servicenow_oauth_client_secret" {
  type        = string
  description = "OAuth client secret for the Application Registry entry."
  sensitive   = true
}

variable "connection_name" {
  type        = string
  description = "Display name for the Octopus → ServiceNow ITSM connection."
  default     = "PDI"
}
