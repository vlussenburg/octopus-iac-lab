output "agent_release_name" {
  value = helm_release.octopus_agent.name
}

output "agent_namespace" {
  value = helm_release.octopus_agent.namespace
}

output "agent_chart_version" {
  value = helm_release.octopus_agent.version
}

output "kubectl_pods_command" {
  value       = "kubectl get pods -n ${helm_release.octopus_agent.namespace}"
  description = "Run this to verify the agent is healthy."
}
