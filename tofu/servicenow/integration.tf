# Octopus ↔ ServiceNow ITSM integration setup.
#
# The integration is space-agnostic Octopus-instance config — there's no
# octopusdeploy_* resource yet (as of provider v1.12), so we drive
# /api/configuration/servicenow-integration/values via a null_resource +
# curl. Re-runs are idempotent because we PUT the whole document.
#
# After this applies:
#   - Integration is enabled globally.
#   - One ITSM connection ("PDI" by default) points at $SERVICENOW_URL,
#     OAuth-authenticated (password grant) — Octopus rejects basic-auth
#     alone at runtime even though the schema permits it.

resource "null_resource" "servicenow_connection" {
  triggers = {
    url                     = var.servicenow_url
    username                = var.servicenow_username
    password_sha256         = sha256(var.servicenow_password)
    oauth_client_id         = var.servicenow_oauth_client_id
    oauth_client_secret_sha = sha256(var.servicenow_oauth_client_secret)
    connection_name         = var.connection_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eu", "-c"]
    environment = {
      OCTO_URL          = var.octopus_url
      OCTO_KEY          = var.octopus_api_key
      SNOW_URL          = var.servicenow_url
      SNOW_USER         = var.servicenow_username
      SNOW_PASS         = var.servicenow_password
      SNOW_OAUTH_ID     = var.servicenow_oauth_client_id
      SNOW_OAUTH_SECRET = var.servicenow_oauth_client_secret
      CONN_NAME         = var.connection_name
    }
    command = <<-EOT
      payload=$(jq -n \
        --arg name      "$CONN_NAME" \
        --arg url       "$SNOW_URL" \
        --arg user      "$SNOW_USER" \
        --arg pass      "$SNOW_PASS" \
        --arg client_id "$SNOW_OAUTH_ID" \
        --arg secret    "$SNOW_OAUTH_SECRET" \
        '{
          IsEnabled: true,
          WorkNotesIsEnabled: true,
          Connections: [{
            ConnectionName:    $name,
            BaseUrl:           $url,
            Username:          $user,
            UserPassword:      { HasValue: true, NewValue: $pass },
            OAuthClientId:     $client_id,
            OAuthClientSecret: { HasValue: true, NewValue: $secret }
          }]
        }')
      curl -s -fL -X PUT \
        -H "X-Octopus-ApiKey: $OCTO_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$OCTO_URL/api/configuration/servicenow-integration/values" > /dev/null
      echo "✓ ServiceNow integration enabled — connection '$CONN_NAME' → $SNOW_URL"

      # Connectivity probe — surfaces a clear error before deploys try to use it.
      probe_payload=$(jq -n \
        --arg url       "$SNOW_URL" \
        --arg user      "$SNOW_USER" \
        --arg pass      "$SNOW_PASS" \
        --arg client_id "$SNOW_OAUTH_ID" \
        --arg secret    "$SNOW_OAUTH_SECRET" \
        '{
          BaseUrl:           $url,
          Username:          $user,
          UserPassword:      $pass,
          OAuthClientId:     $client_id,
          OAuthClientSecret: $secret
        }')
      probe=$(curl -s -X POST \
        -H "X-Octopus-ApiKey: $OCTO_KEY" \
        -H "Content-Type: application/json" \
        -d "$probe_payload" \
        "$OCTO_URL/api/servicenow-integration/connectivity-test")
      echo "Connectivity test: $probe"
    EOT
  }
}
