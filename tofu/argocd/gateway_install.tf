# Octopus Argo CD Gateway — installs into octopus-argo-gateway namespace,
# registers itself in Octopus on install, then opens a single outbound gRPC
# connection back to Octopus that surfaces Argo Applications under
# Infrastructure → Argo CD Instances.
#
# Per-Octopus, like the K8s agent — derive a per-instance release name so
# both worktrees can run gateways into the same cluster against different
# Octopi without colliding.

locals {
  cp = data.terraform_remote_state.control_plane.outputs

  gateway_release_name = "octopus-argo-gateway-${local.target_kind}"

  # Environments the Gateway scopes Argo Application discovery against.
  # Mirrors the k8s-agent install — Dev + Production.
  gateway_environments = ["Dev", "Production"]

  # SaaS exposes gRPC at :443 multiplexed with HTTPS (the public LB does
  # protocol-aware routing). Self-host compose exposes :8443 separately.
  # User can override via var.octopus_grpc_url for any non-default tunnel.
  octopus_host = replace(replace(var.octopus_url, "https://", ""), "http://", "")
  octopus_grpc_url_resolved = coalesce(
    var.octopus_grpc_url,
    local.target_kind == "saas"
    ? "grpc://${local.octopus_host}:443"
    : "grpc://host.docker.internal:8443",
  )

  # The HTTP URL pods use to reach Octopus. SaaS = public URL (works from
  # anywhere). Self-host = host.docker.internal:8090, since localhost in
  # a pod is the pod itself.
  octopus_url_for_pods = local.target_kind == "saas" ? var.octopus_url : var.octopus_url_from_cluster
}

resource "helm_release" "octopus_argo_gateway" {
  name             = local.gateway_release_name
  namespace        = kubernetes_namespace_v1.gateway.metadata[0].name
  create_namespace = false

  repository = "oci://registry-1.docker.io/octopusdeploy"
  chart      = "octopus-argocd-gateway-chart"
  version    = var.gateway_chart_version

  atomic = true
  wait   = true

  # --- registration: Gateway → Octopus HTTP API (one-shot) ----------------

  set {
    name  = "registration.octopus.name"
    value = "argocd-${local.target_kind}"
  }

  # The registration job runs INSIDE the cluster, so this needs the
  # from-cluster URL — `host.docker.internal:8090` for self-host, the
  # public URL for SaaS.
  set {
    name  = "registration.octopus.serverApiUrl"
    value = local.octopus_url_for_pods
  }

  set {
    name  = "registration.octopus.spaceId"
    value = data.terraform_remote_state.space.outputs.space_id
  }

  set_list {
    name  = "registration.octopus.environments"
    value = local.gateway_environments
  }

  set {
    name  = "registration.octopus.serverAccessTokenSecretName"
    value = kubernetes_secret_v1.octopus_access_token.metadata[0].name
  }

  set {
    name  = "registration.octopus.serverAccessTokenSecretKey"
    value = "OCTOPUS_SERVER_ACCESS_TOKEN"
  }

  set {
    name  = "registration.argocd.webUiUrl"
    value = "http://${var.ingress_host}:8080"
  }

  # --- runtime: Gateway → Octopus over gRPC --------------------------------

  set {
    name  = "gateway.octopus.serverGrpcUrl"
    value = local.octopus_grpc_url_resolved
  }

  set {
    name  = "gateway.octopus.plaintext"
    value = var.octopus_grpc_plaintext ? "true" : "false"
  }

  # --- runtime: Gateway → ArgoCD over gRPC ---------------------------------

  set {
    name  = "gateway.argocd.serverGrpcUrl"
    value = "grpc://argocd-server.${local.argocd_namespace_name}.svc.cluster.local:443"
  }

  # argocd-server inside the cluster runs without TLS in our config
  # (configs.params.server.insecure=true above) — tell the Gateway to skip TLS.
  set {
    name  = "gateway.argocd.plaintext"
    value = "true"
  }

  set {
    name  = "gateway.argocd.authenticationTokenSecretName"
    value = kubernetes_secret_v1.octopus_argocd_token.metadata[0].name
  }

  set {
    name  = "gateway.argocd.authenticationTokenSecretKey"
    value = "ARGOCD_AUTH_TOKEN"
  }

  # --- chart-level toggles --------------------------------------------------

  # The chart ships a daily auto-update CronJob. Disable it: tofu manages
  # the chart version, and an out-of-band update would fight the apply loop.
  set {
    name  = "autoUpdate.enabled"
    value = "false"
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_secret_v1.octopus_argocd_token,
    kubernetes_secret_v1.octopus_access_token,
  ]
}
