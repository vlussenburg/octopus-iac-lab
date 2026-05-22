# Provider has no insights_report resource (octopusdeploy ~> 1.12) — upsert
# by name via the REST API. Rename in the UI = next apply creates a duplicate.

locals {
  insights_report_name        = "IaC Lab — all deployments"
  insights_report_description = "Auto-managed: covers every project in the IaC Lab project group across both envs and all three tenants."
  insights_report_body = {
    Name            = local.insights_report_name
    Description     = local.insights_report_description
    ProjectGroupIds = [octopusdeploy_project_group.iac_lab.id]
    ProjectIds      = []
    ChannelIds      = []
    TenantIds = [
      octopusdeploy_tenant.acme_corp.id,
      octopusdeploy_tenant.globex.id,
      octopusdeploy_tenant.initech.id,
    ]
    TenantTags = []
    TenantMode = "TenantedAndUntenanted"
    EnvironmentGroups = [{
      Name = "All envs"
      Environments = [
        octopusdeploy_environment.dev.id,
        octopusdeploy_environment.production.id,
      ]
    }]
    TimeZone  = "UTC"
    IconId    = null
    IconColor = null
  }
}

resource "null_resource" "insights_report" {
  triggers = {
    body = sha1(jsonencode(local.insights_report_body))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eo", "pipefail", "-c"]
    environment = {
      OCTOPUS_URL = var.octopus_url
      API_KEY     = var.octopus_api_key
      SPACE_ID    = data.terraform_remote_state.space.outputs.space_id
      NAME        = local.insights_report_name
      BODY        = jsonencode(local.insights_report_body)
    }
    # partialName is silently ignored on insights/reports — filter in jq.
    command = <<-EOT
      BASE="$OCTOPUS_URL/api/$SPACE_ID/insights/reports"
      ID="$(curl -fsS -H "X-Octopus-ApiKey: $API_KEY" "$BASE" \
        | jq -r --arg n "$NAME" '.Items[] | select(.Name == $n) | .Id' | head -n1)"
      if [ -n "$ID" ]; then
        curl -fsS -o /dev/null -H "X-Octopus-ApiKey: $API_KEY" -H 'Content-Type: application/json' \
          -X PUT "$BASE/$ID" --data "$BODY"
        echo "updated insights report $ID"
      else
        NEW_ID="$(curl -fsS -H "X-Octopus-ApiKey: $API_KEY" -H 'Content-Type: application/json' \
          -X POST "$BASE" --data "$BODY" | jq -r '.Id')"
        echo "created insights report $NEW_ID"
      fi
    EOT
  }
}
