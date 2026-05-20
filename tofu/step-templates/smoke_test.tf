resource "octopusdeploy_step_template" "smoke_test" {
  name            = "Smoke Test - HTTP"
  action_type     = "Octopus.Script"
  step_package_id = "Octopus.Script"
  description     = "Hits an HTTP endpoint N times and asserts latency + success-rate thresholds. Authored in tofu/step-templates/. Consume from Library → Step Templates."

  properties = {
    "Octopus.Action.Script.Syntax"       = "Bash"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/scripts/smoke-test.sh")
    "Octopus.Action.RunOnServer"         = "false"
  }

  packages = []

  # Parameter Ids must be valid UUIDs (provider rejects anything else)
  # and must be PINNED in HCL. Octopus keys consumer step bindings off
  # the UUID, NOT off the parameter name — rotating an Id silently
  # unbinds every project using the template. Pick any UUID (uuidgen)
  # on first author and never touch it again.
  parameters = [
    {
      id               = "a384a893-c74c-4d59-b143-28690d866ea8"
      name             = "BaseUrl"
      label            = "Base URL"
      help_text        = "Required. Scheme + host + optional port. Combined with Path. Example: http://#{AppName}.#{Namespace}.svc.cluster.local"
      default_value    = ""
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "6d735a9c-306d-4832-929f-49557efcc3cc"
      name             = "Path"
      label            = "Path"
      help_text        = "Path appended to Base URL. Default `/`."
      default_value    = "/"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "c7bd4560-6032-43a6-877d-02425d1e1176"
      name             = "Iterations"
      label            = "Iterations"
      help_text        = "Number of requests to send. Default 20."
      default_value    = "20"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "be6bf8a2-4214-4e16-9e93-27726c643b58"
      name             = "ExpectedStatus"
      label            = "Expected HTTP status"
      help_text        = "Each iteration must return this status to count as success. Default 200."
      default_value    = "200"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "2ca895d7-af76-4286-922d-b9593602cd10"
      name             = "MaxLatencyMs"
      label            = "Max latency (ms)"
      help_text        = "Per-request latency ceiling. Requests slower than this count as failures. Default 500."
      default_value    = "500"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "80ecd16a-6916-43f9-b46e-d610fb6aaded"
      name             = "MinSuccessPct"
      label            = "Min success %"
      help_text        = "Overall success-rate floor. If passing iterations are below this, the step fails. Default 95."
      default_value    = "95"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "92595758-5173-4d22-9c52-ac36e7710565"
      name             = "WarmupSeconds"
      label            = "Warmup (s)"
      help_text        = "Sleep this long before the first request — gives Service endpoints + ingress controllers time to settle. Default 5."
      default_value    = "5"
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
    {
      id               = "e689f877-d525-4519-ad49-f8d03c3e87c5"
      name             = "ExpectBody"
      label            = "Body must contain (optional)"
      help_text        = "If set, response body must contain this substring to count as success. Use to catch 200-OK-but-wrong-page regressions (e.g. tenant config rendered)."
      default_value    = ""
      display_settings = { "Octopus.ControlType" = "SingleLineText" }
    },
  ]
}
