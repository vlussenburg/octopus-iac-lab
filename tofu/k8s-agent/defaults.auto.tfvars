# Non-sensitive lab defaults — committed. octopus_url, octopus_api_key come
# in via TF_VAR_* exports from the root .env. octopus_space (id+name) comes
# from tofu/space/ via terraform_remote_state.
#
# octopus_url_from_cluster / octopus_polling_url_from_cluster default to the
# Docker Desktop loopback (host.docker.internal). Override via TF_VAR_* if
# you're targeting a SaaS instance from a Docker Desktop cluster.
kube_context                     = "docker-desktop"
octopus_url_from_cluster         = "http://host.docker.internal:8090"
octopus_polling_url_from_cluster = "https://host.docker.internal:10943"
agent_target_name                = "docker-desktop"
agent_chart_version              = "2.*"
