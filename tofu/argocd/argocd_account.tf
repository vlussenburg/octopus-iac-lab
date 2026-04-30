# Mint a JWT for the `octopus` account in ArgoCD. The gateway module
# consumes this directly as `argocd_jwt`; secrets are materialised inside
# the module per-Octopus to keep call sites declarative.
resource "argocd_account_token" "octopus" {
  account = "octopus"

  # 30-day token, recreate on next apply if within 7d of expiry. Sandbox
  # numbers — tighten for a real env.
  expires_in   = "${30 * 24}h"
  renew_before = "${7 * 24}h"

  depends_on = [helm_release.argocd]
}
