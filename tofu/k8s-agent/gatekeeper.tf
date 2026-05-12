# ─── CLUSTER-WIDE CONTROLLER ─────────────────────────────────────────────
# Lives on main so any branch's `make agent-apply` installs it. Demo branch
# that exercises this: demo/platform-hub-opa (Platform Hub publishes a Rego
# bundle; this controller enforces it at admission as belt-and-suspenders
# behind the in-deploy `conftest` gate).
# ─────────────────────────────────────────────────────────────────────────
#
# OPA Gatekeeper is the admission-controller half of the policy story.
# The deploy-time half lives in the Octopus deployment process (`conftest`
# against the rendered manifests, fed by the Platform Hub bundle) — that
# fails the deploy where the operator is looking. Gatekeeper catches the
# same violations for anything that bypasses Octopus (a stray `kubectl
# apply`, an Argo sync without the PreSync hook, etc.) and surfaces them
# as admission rejections. Same Rego, two enforcement points.
#
# No ConstraintTemplates / Constraints are installed here — those are
# demo-branch material. This file just provides the controller.
resource "null_resource" "gatekeeper" {
  triggers = {
    chart_version = var.gatekeeper_chart_version
    kube_context  = var.kube_context
  }

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install gatekeeper gatekeeper \
        --repo https://open-policy-agent.github.io/gatekeeper/charts \
        --version "${var.gatekeeper_chart_version}" \
        --namespace gatekeeper-system --create-namespace \
        --kube-context "${var.kube_context}" \
        --atomic --wait
    EOT
  }
}
