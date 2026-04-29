# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key, and
# octopus_url_from_cluster / octopus_polling_url_from_cluster come in via
# TF_VAR_* exports from the root .env (per-worktree). The agent's URL pair
# defaults to host.docker.internal flavours when .env doesn't override —
# that's right for local self-host. SaaS .env overrides with the public URL.
kube_context        = "docker-desktop"
agent_target_name   = "docker-desktop"
agent_chart_version = "2.*"
