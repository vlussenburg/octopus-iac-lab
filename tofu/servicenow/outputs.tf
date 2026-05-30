output "connection_name" {
  value       = var.connection_name
  description = "Name of the Octopus → ServiceNow ITSM connection."
}

output "connection_id" {
  value       = data.external.snow_connection.result.id
  description = "Octopus-generated ID of the ServiceNow ITSM connection. Used by tofu/app-randomquotes to enrol the demo project."
}

output "production_env_id" {
  value       = local.production_env_id
  description = "ID of the Production env that's now change-controlled."
}

output "next_steps" {
  value = <<-EOT
    Deploy a release to Production for any tenant:

      octopus release deploy --project servicenow-cr-gate-randomquotes \
        --version <ver> --environment Production --tenant initech \
        --space "IaC Sandbox"

    The deploy will pause and create a Normal Change at ${var.servicenow_url}
    Move the CR through to "Implement" / "Scheduled" in ServiceNow → Octopus
    polls every ~30s, picks up the approval, resumes.
  EOT
}
