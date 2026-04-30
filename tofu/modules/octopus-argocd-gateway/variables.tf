# Inputs match the schema we'd propose for a future
# `octopusdeploy_argocd_gateway` resource. Octopus-flavoured ("name",
# "environments", "space_id") rather than helm-flavoured ("chart_version",
# "values") — when the real provider lands, the migration is "swap the
# implementation, keep the call sites".

# --- identity ---------------------------------------------------------------

variable "name" {
  description = "Gateway name. Surfaced in Octopus UI under Infrastructure → Argo CD Instances. Must be unique within a Space (Octopus refuses POST collisions)."
  type        = string
}

# --- Octopus side ----------------------------------------------------------

variable "octopus_url" {
  description = "Octopus Server URL as seen from the host where tofu runs. Used by the destroy-time deregister step."
  type        = string
}

variable "octopus_url_from_cluster" {
  description = "Octopus Server URL as seen from inside the K8s cluster — the chart's registration Job uses this. Self-host: http://host.docker.internal:8090. SaaS: same as octopus_url."
  type        = string
}

variable "octopus_grpc_url" {
  description = "Octopus gRPC URL the Gateway pod dials. Self-host: grpc://host.docker.internal:8443. SaaS: grpc://<id>.octopus.app:8443."
  type        = string
}

variable "octopus_grpc_plaintext" {
  description = "If true, Gateway connects to Octopus gRPC without TLS. Default false."
  type        = bool
  default     = false
}

variable "octopus_api_key" {
  description = "Octopus API key — used by the registration init Job to create the gateway record, and by the destroy-time DELETE."
  type        = string
  sensitive   = true
}

variable "octopus_space_id" {
  description = "Octopus space ID (e.g. Spaces-4) the gateway registers into."
  type        = string
}

variable "environments" {
  description = "List of Octopus environment names the gateway scopes Argo Application discovery against."
  type        = list(string)
}

# --- ArgoCD side ----------------------------------------------------------

variable "argocd_namespace" {
  description = "Namespace ArgoCD is installed into. Used to build the in-cluster gRPC URL for argocd-server."
  type        = string
  default     = "argocd"
}

variable "argocd_jwt" {
  description = "ArgoCD JWT for the account the Gateway authenticates as (typically minted via argocd_account_token for an `octopus` apiKey account)."
  type        = string
  sensitive   = true
}

variable "web_ui_url" {
  description = "Public URL of the ArgoCD UI. Surfaced in Octopus as the link-out target on the gateway record."
  type        = string
}

# --- chart -----------------------------------------------------------------

variable "chart_version" {
  description = "octopus-argocd-gateway-chart version."
  type        = string
  default     = "1.23.*"
}
