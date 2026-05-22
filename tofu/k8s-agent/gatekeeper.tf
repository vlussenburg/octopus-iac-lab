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

# ConstraintTemplate + Constraint applied to the cluster so the OPA demo
# (demo/platform-hub-opa) actually denies non-compliant deploys without
# requiring a separate per-branch step. Apply ordering: template first, then
# the Constraint that references it. Kept as a null_resource + kubectl
# apply because kubernetes_manifest reads the YAML at plan time and the
# K8sReplicasPerTier CRD doesn't exist until the template's been applied.
resource "null_resource" "gatekeeper_constraint_template" {
  depends_on = [null_resource.gatekeeper]
  triggers = {
    file_sha     = filesha256("${path.module}/constraints/k8sreplicaspertier-template.yaml")
    kube_context = var.kube_context
  }
  provisioner "local-exec" {
    command = "kubectl --context '${var.kube_context}' apply -f ${path.module}/constraints/k8sreplicaspertier-template.yaml"
  }
}

resource "null_resource" "gatekeeper_constraint" {
  depends_on = [null_resource.gatekeeper_constraint_template]
  triggers = {
    file_sha     = filesha256("${path.module}/constraints/k8sreplicaspertier-constraint.yaml")
    kube_context = var.kube_context
  }
  provisioner "local-exec" {
    # Sleep briefly so Gatekeeper's webhook registers the new CRD before
    # the Constraint POST hits the API server (otherwise: "no matches for
    # kind K8sReplicasPerTier"). 5s is comfortable on this lab cluster.
    command = "sleep 5 && kubectl --context '${var.kube_context}' apply -f ${path.module}/constraints/k8sreplicaspertier-constraint.yaml"
  }
}
