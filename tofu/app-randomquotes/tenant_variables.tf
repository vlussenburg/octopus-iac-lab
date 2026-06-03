# Values for the Brand.DisplayName project template (project.tf). This is the
# one genuinely per-tenant value in the lab — a brand name that no tier/mood tag
# can derive. Keeping the values here (not hand-entered on the tenant variables
# page) means a nuked instance gets every customer's display name back on apply.
#
# Scoped to each tenant's environments (local.tenant_environment_keys) — the
# provider requires environment scope, and acme-corp needs the value in Dev too,
# not just Production.
locals {
  tenant_display_names = {
    acme_corp = "Acme Corp"
    globex    = "Globex Corporation"
    initech   = "Initech"
  }

  brand_display_name_template_id = one([
    for t in octopusdeploy_project.randomquotes.template : t.id
    if t.name == "Brand.DisplayName"
  ])
}

resource "octopusdeploy_tenant_project_variable" "brand_display_name" {
  for_each = local.tenant_display_names

  project_id  = octopusdeploy_project.randomquotes.id
  template_id = local.brand_display_name_template_id
  tenant_id   = local.cp.tenant_ids[each.key]
  value       = each.value

  scope {
    environment_ids = [for e in local.tenant_environment_keys[each.key] : local.cp.environment_ids[e]]
  }

  depends_on = [octopusdeploy_tenant_project.tenants]
}
