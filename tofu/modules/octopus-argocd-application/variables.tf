# Inputs match the schema we'd propose for a future
# `octopusdeploy_argocd_application` resource. Keep names Octopus-flavoured
# (project_slug / environment_slug / tenant_slug) rather than Argo-flavoured
# so the eventual provider migration is purely "swap the implementation, keep
# the call sites".

# --- identity ---------------------------------------------------------------

variable "name" {
  description = "Argo Application name. Must be a valid k8s resource name."
  type        = string
}

variable "namespace" {
  description = "Namespace the Argo Application object lives in (NOT the workload namespace — that's `destination_namespace`). Defaults to argocd."
  type        = string
  default     = "argocd"
}

# --- Octopus scoping (the whole point of this module) -----------------------

variable "octopus_project_slug" {
  description = "Octopus project slug. Surfaced as the `argo.octopus.com/project` annotation."
  type        = string
}

variable "octopus_environment_slug" {
  description = "Octopus environment slug (e.g. `dev`, `production`). Surfaced as the `argo.octopus.com/environment` annotation."
  type        = string
}

variable "octopus_tenant_slug" {
  description = "Optional Octopus tenant slug (e.g. `acme-corp`). When set, surfaced as the `argo.octopus.com/tenant` annotation."
  type        = string
  default     = null
}

variable "image_replace_paths" {
  description = "Optional helm-template string identifying the image attribute Octopus should rewrite on deploy. See https://octopus.com/docs/argo-cd/annotations/helm-annotations. Comma-delimit for multiple images."
  type        = string
  default     = null
}

# --- Argo Application source ------------------------------------------------

variable "source_repo_url" {
  description = "Git repository the Application syncs from."
  type        = string
}

variable "source_path" {
  description = "Path within the repo containing manifests (or chart, for helm sources)."
  type        = string
}

variable "source_target_revision" {
  description = "Git ref to track. `HEAD` for trunk-following, a branch name, a tag, or a commit SHA."
  type        = string
  default     = "HEAD"
}

# --- Argo Application destination -------------------------------------------

variable "destination_server" {
  description = "Argo cluster destination URL. `https://kubernetes.default.svc` is the in-cluster default."
  type        = string
  default     = "https://kubernetes.default.svc"
}

variable "destination_namespace" {
  description = "Workload namespace the Application syncs INTO."
  type        = string
}

# --- Argo project + sync policy ---------------------------------------------

variable "argocd_project" {
  description = "Argo CD project (the AppProject object) that owns this Application. `default` covers all clusters/namespaces."
  type        = string
  default     = "default"
}

variable "sync_automated" {
  description = "If true, Argo continuously syncs the Application without manual intervention."
  type        = bool
  default     = true
}

variable "sync_prune" {
  description = "If true (and sync_automated), Argo deletes resources that disappear from git."
  type        = bool
  default     = true
}

variable "sync_self_heal" {
  description = "If true (and sync_automated), Argo reverts in-cluster drift back to the git state."
  type        = bool
  default     = true
}

variable "sync_create_namespace" {
  description = "If true, Argo creates the destination namespace if missing."
  type        = bool
  default     = true
}

# --- escape hatches ---------------------------------------------------------

variable "extra_annotations" {
  description = "Additional annotations merged into the Application metadata. Octopus's `argo.octopus.com/*` set is added separately."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels to set on the Application. Octopus's integration is annotation-only, so labels are purely for your own selectors."
  type        = map(string)
  default     = {}
}
