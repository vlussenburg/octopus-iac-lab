# Non-sensitive lab defaults — committed. Sensitive values (octopus_api_key)
# come in via TF_VAR_* exports from the root .env.
octopus_url              = "http://localhost:8090"
octopus_space            = "Spaces-1"
octopus_space_name       = "Default"
kube_context             = "docker-desktop"
octopus_url_from_cluster         = "http://host.docker.internal:8090"
octopus_polling_url_from_cluster = "https://host.docker.internal:10943"
agent_target_name        = "docker-desktop"
agent_chart_version      = "2.*"
