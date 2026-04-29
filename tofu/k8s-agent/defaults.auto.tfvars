# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key,
# octopus_url_from_cluster, octopus_polling_url_from_cluster, and
# agent_target_name come in via TF_VAR_* exports from the root .env
# (per-worktree). agent_target_name auto-derives from OCTOPUS_URL in the
# Makefile: *.octopus.app → octopus-tentacle-saas, else octopus-tentacle-local.
kube_context        = "docker-desktop"
agent_chart_version = "2.*"
