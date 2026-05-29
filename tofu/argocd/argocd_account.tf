# Mint a JWT for this worktree's scoped Argo account (octopus-local /
# octopus-saas). The gateway module consumes it as `argocd_jwt`; the secret
# is materialised inside the module per-Octopus. Only the JWT *content*
# changes here — the secret name the gateway helm release references is
# static, so swapping accounts is an in-place secret update, NOT a helm
# upgrade (which would re-run the gateway's non-idempotent registration hook).
resource "argocd_account_token" "octopus" {
  account = "octopus-${local.target_kind}"

  # 30-day token, recreate on next apply if within 7d of expiry. Sandbox
  # numbers — tighten for a real env.
  expires_in   = "${30 * 24}h"
  renew_before = "${7 * 24}h"

  depends_on = [helm_release.argocd]
}
