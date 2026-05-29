# A deployment target serves an ephemeral environment only if it's scoped to
# that env's PARENT — ephemeral children inherit the parent's targets. The agent
# self-registers (helm chart's agent.deploymentTarget.initial.environments)
# against Dev + Production only, and that list applies once at registration, so
# it can neither add the Previews parent to a fresh target nor re-scope an
# existing one. Without this, native ephemeral preview deploys fail with
# "No active machines were found in the environment" and no preview ever lands.
#
# PATCH the registered target to union-in the Previews parent env id (resolved
# from app-randomquotes state — parent envs aren't queryable by name). Idempotent
# union, so re-runs and already-scoped targets are no-ops.
resource "null_resource" "agent_previews_scope" {
  triggers = {
    octopus_url = var.octopus_url
    api_key     = var.octopus_api_key
    space_id    = data.terraform_remote_state.space.outputs.space_id
    target_name = local.agent_target_name
    parent_env  = data.terraform_remote_state.app.outputs.previews_parent_environment_id
  }

  provisioner "local-exec" {
    # Registration is async after the helm release reports ready, so poll for the
    # target by name, then GET/union/PUT its EnvironmentIds.
    command = <<-EOT
      set -e
      BASE="${self.triggers.octopus_url}/api/${self.triggers.space_id}"
      KEY="${self.triggers.api_key}"
      PARENT="${self.triggers.parent_env}"
      NAME="${self.triggers.target_name}"
      for i in $(seq 1 30); do
        M=$(curl -sf -H "X-Octopus-ApiKey: $KEY" "$BASE/machines?partialName=$NAME" | python3 -c 'import sys,json; items=json.load(sys.stdin).get("Items",[]); print(items[0]["Id"] if items else "")') || M=""
        [ -n "$M" ] && break
        sleep 4
      done
      [ -n "$M" ] || { echo "agent target $NAME not found after registration"; exit 1; }
      BODY=$(curl -sf -H "X-Octopus-ApiKey: $KEY" "$BASE/machines/$M" | PARENT="$PARENT" python3 -c 'import sys,json,os; m=json.load(sys.stdin); p=os.environ["PARENT"]; m["EnvironmentIds"]=sorted(set(m.get("EnvironmentIds",[])+[p])); json.dump(m,sys.stdout)')
      curl -sf -X PUT -H "X-Octopus-ApiKey: $KEY" -H "Content-Type: application/json" -d "$BODY" "$BASE/machines/$M" >/dev/null
      echo "scoped $NAME to previews parent env $PARENT"
    EOT
  }

  depends_on = [helm_release.octopus_agent]
}
