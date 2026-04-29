# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key,
# octopus_url_from_cluster, and octopus_polling_url_from_cluster come in
# via TF_VAR_* exports from .env. The agent target name is computed in
# locals from var.octopus_url.
kube_context        = "docker-desktop"
agent_chart_version = "2.*"
