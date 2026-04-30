# Mint a JWT for the `octopus` account, then materialise it as a Kubernetes
# Secret in the gateway's namespace so the Gateway helm release can mount
# `gateway.argocd.authenticationTokenSecretName`.
#
# argocd_account_token has built-in renewal: we set `expires_in_days` so
# tofu will recreate the token before it expires.

resource "argocd_account_token" "octopus" {
  account = "octopus"

  # 30-day token, recreate on next apply if within 7d of expiry. Sandbox
  # numbers — tighten for a real env.
  expires_in   = "${30 * 24}h"
  renew_before = "${7 * 24}h"

  depends_on = [helm_release.argocd]
}

resource "kubernetes_namespace_v1" "gateway" {
  metadata {
    # Per-Octopus suffixed: both worktrees install gateways into the same
    # cluster, so each gets its own namespace.
    name = "octopus-argo-gateway-${local.target_kind}"
  }
}

resource "kubernetes_secret_v1" "octopus_argocd_token" {
  metadata {
    name      = "argocd-octopus-token"
    namespace = kubernetes_namespace_v1.gateway.metadata[0].name
  }

  data = {
    # Default key the Gateway chart looks at unless overridden.
    ARGOCD_AUTH_TOKEN = argocd_account_token.octopus.jwt
  }
}

# Octopus access token Secret — referenced by the Gateway chart so the
# registration init Job can call Octopus's HTTP API. Same shape as the JWT
# secret: one key, default name the chart looks for.
resource "kubernetes_secret_v1" "octopus_access_token" {
  metadata {
    name      = "octopus-access-token"
    namespace = kubernetes_namespace_v1.gateway.metadata[0].name
  }

  data = {
    OCTOPUS_SERVER_ACCESS_TOKEN = var.octopus_api_key
  }
}
