# Weekly maintenance window for Production: 1am-2am Pacific on Mondays.
# Triggers can't live in OCL/CaC yet — Octopus's Config-as-Code coverage
# stops at deployment process / variables / runbooks. So they're managed
# here in tofu and target the git-stored runbooks via data lookups.

# Tenant tags (e.g. app/randomquotes) aren't a supported scope on
# octopusdeploy_project_scheduled_trigger — we have to resolve to explicit
# tenant IDs. Fan tenants out by their `app/randomquotes` tag.
data "octopusdeploy_tenants" "randomquotes" {
  tags = ["app/randomquotes"]
}

resource "octopusdeploy_project_scheduled_trigger" "maintenance_on_weekly" {
  name        = "Weekly maintenance ON (Production, Mon 01:00 PT)"
  description = "Puts Production tenants into maintenance mode every Monday at 01:00 Pacific. Pairs with the OFF trigger one hour later."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  project_id  = octopusdeploy_project.randomquotes.id
  timezone    = "Pacific Standard Time"
  tenant_ids  = data.octopusdeploy_tenants.randomquotes.tenants[*].id

  cron_expression_schedule {
    # Quartz cron: sec min hour day-of-month month day-of-week
    cron_expression = "0 0 1 ? * MON"
  }

  run_runbook_action {
    # Git-stored runbooks use their slug as the ID — hardcoded since the
    # provider has no `octopusdeploy_runbook` data source for lookup.
    runbook_id             = "maintenance-on"
    target_environment_ids = [local.cp.environment_ids.production]
  }
}

resource "octopusdeploy_project_scheduled_trigger" "maintenance_off_weekly" {
  name        = "Weekly maintenance OFF (Production, Mon 02:00 PT)"
  description = "Clears the maintenance overlay one hour after the ON trigger fires."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  project_id  = octopusdeploy_project.randomquotes.id
  timezone    = "Pacific Standard Time"
  tenant_ids  = data.octopusdeploy_tenants.randomquotes.tenants[*].id

  cron_expression_schedule {
    cron_expression = "0 0 2 ? * MON"
  }

  run_runbook_action {
    runbook_id             = "maintenance-off"
    target_environment_ids = [local.cp.environment_ids.production]
  }
}
