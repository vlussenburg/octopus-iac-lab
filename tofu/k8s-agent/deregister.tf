# The K8s Agent helm chart self-registers a deployment target in Octopus
# during install. Uninstalling the helm release tears down the K8s pod but
# leaves the Octopus-side target record orphaned, which then blocks env
# deletion ("environment has deployment targets assigned").
#
# This null_resource has only a destroy-time provisioner: it calls the
# Octopus API to remove the target by name. depends_on the helm release so
# the destroy order is:
#   1. null_resource.deregister_agent destroyed → DELETE /machines/{id}
#   2. helm_release.octopus_agent destroyed     → helm uninstall
# Apply order is reversed (helm release first, then null_resource), but the
# null_resource's create is a no-op (no `command` outside `when = destroy`).
resource "null_resource" "deregister_agent" {
  triggers = {
    octopus_url     = var.octopus_url
    octopus_api_key = var.octopus_api_key
    space_id        = data.terraform_remote_state.space.outputs.space_id
    target_name     = local.agent_target_name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      ID=$(curl -sf -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
        "${self.triggers.octopus_url}/api/${self.triggers.space_id}/machines?partialName=${self.triggers.target_name}" \
        | jq -r '.Items[] | select(.Name == "${self.triggers.target_name}") | .Id' | head -n1)
      if [ -n "$ID" ]; then
        curl -sf -X DELETE -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/machines/$ID" >/dev/null
        echo "Deregistered ${self.triggers.target_name} ($ID)"
      else
        echo "No deployment target named ${self.triggers.target_name} — already gone"
      fi
    EOT
  }

  depends_on = [helm_release.octopus_agent]
}
