# Destroy-time cleanup for the Gateway's Octopus-side registration record.
#
# Provider-gap pattern, mirrors `tofu/k8s-agent/deregister.tf`. Octopus's
# `POST /api/{space}/argocdgateways` endpoint is one-way: the helm chart's
# registration init Job calls it on install, but Octopus refuses a second
# POST with the same name ("An ArgoCDGateway with this name already exists.").
# So a `helm uninstall` alone leaves an orphan record that blocks every
# subsequent re-install.
#
# Until `octopusdeploy_argocd_gateway` is a real provider resource (the
# whole reason the local module exists), we close the loop here:
#   1. helm install         → registration job creates ArgoCDGateways-N
#   2. helm uninstall        → tofu calls DELETE on that record before the
#                              helm release destroys, so the next install
#                              starts clean.
#
# `octopus_argo_gateway` depends on `argocd_account_token` and the Secrets;
# we depend on the helm release so destroy ordering is:
#   helm_release destroyed → null_resource destroyed → DELETE on Octopus
# (the destroy-time provisioner runs BEFORE the resource's state is removed,
# but tofu has already torn down the helm release by then.)
resource "null_resource" "deregister_gateway" {
  triggers = {
    octopus_url     = var.octopus_url
    octopus_api_key = var.octopus_api_key
    space_id        = data.terraform_remote_state.space.outputs.space_id
    gateway_name    = "argocd-${local.target_kind}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      ID=$(curl -sf -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
        "${self.triggers.octopus_url}/api/${self.triggers.space_id}/argocdgateways/ArgoCDGateways-1" \
        2>/dev/null | jq -r --arg n "${self.triggers.gateway_name}" 'select(.Resource.Name == $n) | .Resource.Id // empty')
      # ArgoCDGateways-1 may not be ours — fall back to scanning a small range.
      if [ -z "$ID" ]; then
        for i in 1 2 3 4 5 6 7 8 9 10; do
          NAME=$(curl -sf -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
            "${self.triggers.octopus_url}/api/${self.triggers.space_id}/argocdgateways/ArgoCDGateways-$i" \
            2>/dev/null | jq -r '.Resource.Name // empty')
          if [ "$NAME" = "${self.triggers.gateway_name}" ]; then
            ID="ArgoCDGateways-$i"
            break
          fi
        done
      fi
      if [ -n "$ID" ]; then
        curl -sf -X DELETE -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/argocdgateways/$ID" >/dev/null
        echo "Deregistered ${self.triggers.gateway_name} ($ID)"
      else
        echo "No registration found for ${self.triggers.gateway_name} — already gone"
      fi
    EOT
  }

  depends_on = [helm_release.octopus_argo_gateway]
}
