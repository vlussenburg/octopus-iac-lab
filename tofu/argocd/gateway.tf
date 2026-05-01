# Octopus Argo CD Gateway — wraps the chart + registration + deregistration
# in the local `octopus-argocd-gateway` module. That module is the
# placeholder for what we'd hope eventually ships as
# `octopusdeploy_argocd_gateway` in the OctopusDeploy provider.

locals {
  # SaaS exposes Octopus gRPC on :8443 with a public TLS cert. Self-host
  # compose maps host :18443 → container :8443 (Docker Desktop reserves
  # *:8443 on macOS, so we dodge by binding 18443 on the host).
  octopus_host = replace(replace(var.octopus_url, "https://", ""), "http://", "")
  octopus_grpc_url_resolved = coalesce(
    var.octopus_grpc_url,
    local.is_saas
    ? "grpc://${local.octopus_host}:8443"
    : "grpc://host.docker.internal:18443",
  )

  # The HTTP URL pods use to reach Octopus. SaaS = public URL (works from
  # anywhere). Self-host = host.docker.internal:8090 (localhost in a pod
  # is the pod itself, not Docker's host).
  octopus_url_for_pods = local.is_saas ? var.octopus_url : var.octopus_url_from_cluster
}

module "gateway" {
  source = "../modules/octopus-argocd-gateway"

  name                     = "argocd-${local.target_kind}"
  octopus_url              = var.octopus_url
  octopus_url_from_cluster = local.octopus_url_for_pods
  octopus_grpc_url         = local.octopus_grpc_url_resolved
  octopus_grpc_plaintext   = var.octopus_grpc_plaintext
  octopus_api_key          = var.octopus_api_key
  octopus_space_id         = data.terraform_remote_state.space.outputs.space_id
  environments             = ["Dev", "Production"]

  argocd_namespace = local.argocd_namespace_name
  argocd_jwt       = argocd_account_token.octopus.jwt

  web_ui_url    = "http://${var.ingress_host}:8080"
  chart_version = var.gateway_chart_version

  depends_on = [
    helm_release.argocd,
  ]
}
