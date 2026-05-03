# Library variable set holding per-Octopus values that the CaC project
# references but can't carry in OCL (OCL is shared across both Octopi —
# values that differ per instance must live in HCL).
#
# Right now: just `Source` = local | saas. Used to build per-(source,
# tenant, env) namespace names without parsing the agent's name with a
# magic-number Substring.

locals {
  # Same derivation as agent name: `*.octopus.app` host → SaaS, otherwise
  # local. Each Octopus's HCL apply produces the right value for itself.
  source_kind = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"
}

resource "octopusdeploy_library_variable_set" "lab_source" {
  name        = "lab-source"
  description = "Per-Octopus identity (local vs saas). Included by the randomquotes project."
}

resource "octopusdeploy_variable" "source" {
  owner_id = octopusdeploy_library_variable_set.lab_source.id
  name     = "Source"
  type     = "String"
  value    = local.source_kind
}

# GitHub PAT exposed as a sensitive script variable so runbook steps that
# commit to git (e.g. the maintenance-on/off runbooks' "Set Argo
# Maintenance" step) can authenticate the push. The same PAT is already
# stored as an Octopus Git credential for CaC, but Git credentials aren't
# directly addressable from script steps — they're consumed internally by
# Octopus's Git plumbing. Hence this duplication.
resource "octopusdeploy_variable" "github_token" {
  owner_id        = octopusdeploy_library_variable_set.lab_source.id
  name            = "GitHub.Token"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = var.github_pat
}

# Worker pool name to target for bash script steps. SaaS's default dynamic
# worker is Windows ("Hosted Windows") and there's no /bin/bash there;
# pin to "Hosted Ubuntu" instead. Local self-host has only "Default Worker
# Pool" (the built-in Octopus Server worker, which is Linux).
# Used by runbook script steps via Octopus.Action.WorkerPoolVariable.
resource "octopusdeploy_variable" "linux_worker_pool" {
  owner_id = octopusdeploy_library_variable_set.lab_source.id
  name     = "Linux.WorkerPool"
  type     = "WorkerPool"
  value    = local.source_kind == "saas" ? "worker-pools-hosted-ubuntu" : "default-worker-pool"
}
