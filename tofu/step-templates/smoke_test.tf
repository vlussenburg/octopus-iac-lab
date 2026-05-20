# Smoke Test - HTTP : Library step template.
#
# Hits an HTTP endpoint N times and asserts latency + success-rate
# thresholds. Authored once here, surfaced in the consuming Space's
# Library → Step Templates, addable to any project's deployment process
# from the UI. Replaces the copy-paste curl loops every team writes the
# first time someone asks "did the deploy actually work?".

locals {
  smoke_test_template_name = "Smoke Test - HTTP"
  smoke_test_script_body   = file("${path.module}/scripts/smoke-test.sh")

  smoke_test_parameters = [
    {
      Name            = "BaseUrl"
      Label           = "Base URL"
      HelpText        = "Required. Scheme + host + optional port. Combined with Path. Example: http://#{AppName}.#{Namespace}.svc.cluster.local"
      DefaultValue    = ""
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "Path"
      Label           = "Path"
      HelpText        = "Path appended to Base URL. Default `/`."
      DefaultValue    = "/"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "Iterations"
      Label           = "Iterations"
      HelpText        = "Number of requests to send. Default 20."
      DefaultValue    = "20"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "ExpectedStatus"
      Label           = "Expected HTTP status"
      HelpText        = "Each iteration must return this status to count as success. Default 200."
      DefaultValue    = "200"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "MaxLatencyMs"
      Label           = "Max latency (ms)"
      HelpText        = "Per-request latency ceiling. Requests slower than this count as failures. Default 500."
      DefaultValue    = "500"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "MinSuccessPct"
      Label           = "Min success %"
      HelpText        = "Overall success-rate floor. If passing iterations are below this, the step fails. Default 95."
      DefaultValue    = "95"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "WarmupSeconds"
      Label           = "Warmup (s)"
      HelpText        = "Sleep this long before the first request — gives Service endpoints + ingress controllers time to settle. Default 5."
      DefaultValue    = "5"
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      Name            = "ExpectBody"
      Label           = "Body must contain (optional)"
      HelpText        = "If set, response body must contain this substring to count as success. Use to catch 200-OK-but-wrong-page regressions (e.g. tenant config rendered)."
      DefaultValue    = ""
      DisplaySettings = { "Octopus.ControlType" = "SingleLineText" }
    },
  ]

  smoke_test_payload = jsonencode({
    Name          = local.smoke_test_template_name
    Description   = "Hits an HTTP endpoint N times and asserts latency + success-rate thresholds. Authored in tofu/step-templates/. Consume from Library → Step Templates."
    ActionType    = "Octopus.Script"
    StepPackageId = "Octopus.Script"
    Packages      = []
    Properties = {
      "Octopus.Action.Script.Syntax"       = "Bash"
      "Octopus.Action.Script.ScriptSource" = "Inline"
      "Octopus.Action.Script.ScriptBody"   = local.smoke_test_script_body
      "Octopus.Action.RunOnServer"         = "true"
    }
    Parameters = local.smoke_test_parameters
  })
}

resource "null_resource" "smoke_test" {
  triggers = {
    # Re-apply when name, script, or parameter shape changes.
    payload_sha256 = sha256(local.smoke_test_payload)
    space_id       = data.terraform_remote_state.space.outputs.space_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-eu", "-o", "pipefail", "-c"]
    environment = {
      OCTO_URL = var.octopus_url
      OCTO_KEY = var.octopus_api_key
      SPACE_ID = data.terraform_remote_state.space.outputs.space_id
      TPL_NAME = local.smoke_test_template_name
      PAYLOAD  = local.smoke_test_payload
    }
    command = <<-EOT
      base="$OCTO_URL/api/$SPACE_ID/actiontemplates"

      # Look up existing by name (action templates have unique names per space).
      existing_id=$(curl -s -fL \
        -H "X-Octopus-ApiKey: $OCTO_KEY" \
        --get --data-urlencode "partialName=$TPL_NAME" \
        "$base" \
        | jq -r --arg n "$TPL_NAME" '.Items[] | select(.Name == $n) | .Id' | head -1)

      if [ -n "$existing_id" ]; then
        echo "→ updating $existing_id ($TPL_NAME)"
        curl -s -fL -X PUT \
          -H "X-Octopus-ApiKey: $OCTO_KEY" \
          -H "Content-Type: application/json" \
          -d "$PAYLOAD" \
          "$base/$existing_id" \
          | jq -r '"✓ updated: " + .Id + " v" + (.Version|tostring) + " slug=" + (.Slug // "(none)")'
      else
        echo "→ creating $TPL_NAME"
        curl -s -fL -X POST \
          -H "X-Octopus-ApiKey: $OCTO_KEY" \
          -H "Content-Type: application/json" \
          -d "$PAYLOAD" \
          "$base" \
          | jq -r '"✓ created: " + .Id + " v" + (.Version|tostring) + " slug=" + (.Slug // "(none)")'
      fi
    EOT
  }
}

# Destroy-time cleanup. Looks up by name (the resource Id isn't in tfstate
# because null_resource doesn't capture it) and DELETEs.
resource "null_resource" "smoke_test_destroy" {
  triggers = {
    octopus_url     = var.octopus_url
    octopus_api_key = var.octopus_api_key
    space_id        = data.terraform_remote_state.space.outputs.space_id
    template_name   = local.smoke_test_template_name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-eu", "-o", "pipefail", "-c"]
    environment = {
      OCTO_URL = self.triggers.octopus_url
      OCTO_KEY = self.triggers.octopus_api_key
      SPACE_ID = self.triggers.space_id
      TPL_NAME = self.triggers.template_name
    }
    command = <<-EOT
      base="$OCTO_URL/api/$SPACE_ID/actiontemplates"
      existing_id=$(curl -s -fL \
        -H "X-Octopus-ApiKey: $OCTO_KEY" \
        --get --data-urlencode "partialName=$TPL_NAME" \
        "$base" \
        | jq -r --arg n "$TPL_NAME" '.Items[] | select(.Name == $n) | .Id' | head -1)
      if [ -n "$existing_id" ]; then
        curl -s -fL -X DELETE \
          -H "X-Octopus-ApiKey: $OCTO_KEY" \
          "$base/$existing_id" \
          && echo "✓ deleted $existing_id ($TPL_NAME)"
      else
        echo "(none) nothing to delete: no template named '$TPL_NAME'"
      fi
    EOT
  }
}
