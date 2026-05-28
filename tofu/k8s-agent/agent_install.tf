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
  agent_tenants      = ["acme-corp", "globex", "initech"]

  # The agent pod's config is per-Octopus — server URL and bearer token are
  # baked in at install time. When two stacks target the same K8s cluster
  # against different Octopus instances, each needs a distinct helm release
  # and namespace. Derive the suffix from the URL.
  target_kind       = strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"
  agent_target_name = "octopus-tentacle-${local.target_kind}"

  # KLOS monitor gRPC endpoint. SaaS hits the public host on :8443 (public
  # cert). Self-host compose maps host :18443 → container :8443 (Docker
  # Desktop reserves *:8443 on macOS) — mirrors the Argo Gateway's resolution.
  octopus_host     = replace(replace(var.octopus_url, "https://", ""), "http://", "")
  monitor_grpc_url = local.target_kind == "local" ? "grpc://host.docker.internal:18443" : "grpc://${local.octopus_host}:8443"
  # Self-host gRPC cert is self-signed and regenerates on every DB rebuild, so
  # the thumbprint is fetched live (below). SaaS uses a public cert — empty.
  monitor_thumbprint = local.target_kind == "local" ? one(data.external.octopus_grpc_thumbprint[*].result.thumbprint) : ""
}

# Fetch the live gRPC cert thumbprint at apply time so KLOS survives a
# `make nuke` (the self-signed cert is reissued, a hardcoded value would go
# stale). tofu runs on the host, where the container's :8443 is published on
# :18443. Self-host only — SaaS trusts the public cert via system CAs.
data "external" "octopus_grpc_thumbprint" {
  count   = local.target_kind == "local" ? 1 : 0
  program = ["bash", "-c", "TP=$(echo | openssl s_client -connect localhost:18443 2>/dev/null | openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'); printf '{\"thumbprint\":\"%s\"}' \"$TP\""]
}

resource "kubernetes_namespace_v1" "agent" {
  metadata {
    name = "octopus-agent-${local.agent_target_name}"
  }
}

resource "helm_release" "octopus_agent" {
  name             = local.agent_target_name
  namespace        = kubernetes_namespace_v1.agent.metadata[0].name
  create_namespace = false

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

  # Register this target as a participant for every tenant. The project is
  # tenanted, so deployments must select a tenant — the agent serves all
  # three from the same pod (their per-tenant variation comes from
  # variables.ocl, not from agent identity).
  set_list {
    name  = "agent.deploymentTarget.initial.tenants"
    value = local.agent_tenants
  }

  # "TenantedOrUntenanted" lets the same target serve both tenanted projects
  # (like randomquotes) and untenanted ones — useful so you don't have to
  # spin up a second agent for each shape. Tighten back to "Tenanted" if
  # you only ever deploy tenanted.
  set {
    name  = "agent.deploymentTarget.initial.tenantedDeploymentParticipation"
    value = "TenantedOrUntenanted"
  }

  # KLOS (Kubernetes Live Object Status). The in-cluster monitor binds to the
  # agent's existing deployment target (a pre-upgrade hook looks the agent
  # machine up by name and links the monitor to it), then dials the gRPC
  # endpoint validated by the self-signed cert thumbprint fetched above and
  # streams live object health for whatever that target deploys.
  set {
    name  = "kubernetesMonitor.enabled"
    value = "true"
  }

  set {
    name  = "kubernetesMonitor.registration.serverApiUrl"
    value = var.octopus_url_from_cluster
  }

  set_sensitive {
    name  = "kubernetesMonitor.registration.serverAccessToken"
    value = var.octopus_api_key
  }

  set {
    name  = "kubernetesMonitor.registration.spaceId"
    value = data.terraform_remote_state.space.outputs.space_id
  }

  # The monitor attaches to the EXISTING agent's deployment target and streams
  # that target's live object status — it does NOT register a machine of its
  # own. `machineName` is therefore the agent's machine name (the monitor's
  # `register` looks this machine up by name to bind to it); pointing it at a
  # non-existent name makes the pre-upgrade hook poll forever and time out,
  # which is what `atomic` then rolls back.
  set {
    name  = "kubernetesMonitor.registration.machineName"
    value = local.agent_target_name
  }

  set {
    name  = "kubernetesMonitor.monitor.serverGrpcUrl"
    value = local.monitor_grpc_url
  }

  set {
    name  = "kubernetesMonitor.monitor.serverThumbprint"
    value = local.monitor_thumbprint
  }

  # PVC binding needs the NFS CSI driver to be live before the tentacle pod
  # tries to attach its volume. The driver is installed idempotently via
  # null_resource + `helm upgrade --install` (see nfs_csi.tf).
  depends_on = [null_resource.nfs_csi_driver]
}
