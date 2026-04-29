variable "octopus_url" {
  type        = string
  description = "Base URL of the Octopus Server (e.g. http://localhost:8090)."
}

variable "octopus_api_key" {
  type        = string
  description = "Octopus API key. Passed straight through to the helm chart as agent.bearerToken (Octopus accepts API keys as Bearer auth)."
  sensitive   = true
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context to use. Default 'docker-desktop'."
  default     = "docker-desktop"
}

# The Octopus server URL as the agent (running inside K8s) sees it.
# Docker Desktop's K8s nodes can reach the host via host.docker.internal.
variable "octopus_url_from_cluster" {
  type        = string
  description = "HTTP URL the agent uses for the one-time registration call to Octopus. From inside Docker Desktop K8s, the host is reachable via host.docker.internal."
  default     = "http://host.docker.internal:8090"
}

# Halibut is the TLS-over-TCP protocol Polling Tentacles (and K8s Agents) use
# to talk to Octopus continuously after registration. Octopus listens on 10943
# inside the container; we map that to the host in compose/docker-compose.yml.
variable "octopus_polling_url_from_cluster" {
  type        = string
  description = "Halibut (polling) URL. Always TLS — even with HTTP on the API, Halibut uses self-signed TLS certs."
  default     = "https://host.docker.internal:10943"
}

variable "agent_target_name" {
  type        = string
  description = "Name of the deployment target Octopus registers for this agent. Auto-derived from OCTOPUS_URL by the Makefile — octopus-tentacle-{local,saas}."
}

variable "agent_chart_version" {
  type        = string
  description = "Octopus K8s Agent helm chart version constraint."
  default     = "2.*"
}

variable "nfs_csi_chart_version" {
  type        = string
  description = "csi-driver-nfs helm chart version constraint. Applied via helm upgrade --install — idempotent across worktrees, so any worktree can run apply safely."
  default     = "v4.*"
}
