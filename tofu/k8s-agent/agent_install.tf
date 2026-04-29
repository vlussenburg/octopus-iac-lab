# Installs the Octopus K8s Agent helm chart. The chart self-registers a
# deployment target in Octopus using the bearer token, ties it to the
# Dev + Production environments from control-plane, and tags it with the
# "k8s" role our deployment_process.ocl targets.
locals {
  cp = data.terraform_remote_state.control_plane.outputs

  # The provider exposes env IDs as a map; the chart wants names.
  # We resolve names by hitting the Octopus API in another data source...
  # ...actually simpler: store names as locals and use them directly,
  # since Dev/Production are stable in this lab.
  agent_environments = ["Dev", "Production"]
  agent_roles        = ["k8s"]

  # Two worktrees can target the same Docker Desktop K8s — one against a
  # local self-host, one against an Octopus Cloud SaaS instance. The agent
  # pod's config is per-Octopus-target, so each worktree needs a distinct
  # helm release and namespace. Derive the suffix from the URL so the
  # right pod stays attached to the right Octopus.
  target_kind       = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"
  agent_target_name = "octopus-tentacle-${local.target_kind}"
}

resource "helm_release" "octopus_agent" {
  name             = local.agent_target_name
  namespace        = "octopus-agent-${local.agent_target_name}"
  create_namespace = true

  repository = "oci://registry-1.docker.io/octopusdeploy"
  chart      = "kubernetes-agent"
  version    = var.agent_chart_version

  atomic = true

  set {
    name  = "agent.acceptEula"
    value = "Y"
  }

  set {
    name  = "agent.space"
    value = data.terraform_remote_state.space.outputs.space_name
  }

  set {
    name  = "agent.serverUrl"
    value = var.octopus_url_from_cluster
  }

  # Polling uses Halibut (TLS over TCP) on a different port than the HTTP API.
  set {
    name  = "agent.serverCommsAddresses"
    value = "{${var.octopus_polling_url_from_cluster}}"
  }

  # Localhost lab — using the admin API key directly. Octopus accepts API keys
  # as Bearer auth, so no separate registration token is needed. Replace with
  # a scoped service-account API key when this stops being a personal sandbox.
  set_sensitive {
    name  = "agent.bearerToken"
    value = var.octopus_api_key
  }

  set {
    name  = "agent.name"
    value = local.agent_target_name
  }

  set {
    name  = "agent.deploymentTarget.enabled"
    value = "true"
  }

  set_list {
    name  = "agent.deploymentTarget.initial.environments"
    value = local.agent_environments
  }

  set_list {
    name  = "agent.deploymentTarget.initial.tags"
    value = local.agent_roles
  }

  # KLOS (live status / kubernetes monitor) deliberately disabled — it needs
  # an additional gRPC port (8443) exposed from the Octopus container, which
  # our compose stack doesn't open. Toggle on once that's wired.
  set {
    name  = "kubernetesMonitor.enabled"
    value = "false"
  }

  # PVC binding needs the NFS CSI driver to be live before the tentacle pod
  # tries to attach its volume. The driver is installed idempotently via
  # null_resource + `helm upgrade --install` (see nfs_csi.tf).
  depends_on = [null_resource.nfs_csi_driver]
}
