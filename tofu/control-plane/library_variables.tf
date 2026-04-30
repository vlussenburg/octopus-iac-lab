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
