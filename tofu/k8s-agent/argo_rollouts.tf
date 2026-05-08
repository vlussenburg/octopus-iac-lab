# Argo Rollouts controller, cluster-wide infra. Provides the `Rollout` CRD
# (drop-in replacement for `Deployment`) plus the controller that drives
# blue/green and canary strategies, manages active/preview Services, and
# coordinates promotion. Same `helm upgrade --install` survive-destroy
# pattern as the other shared releases here — the CRD is consumed by any
# chart that opts in via a Helm value, so the controller has to live above
# any single deployment.
resource "null_resource" "argo_rollouts" {
  triggers = {
    chart_version = var.argo_rollouts_chart_version
    kube_context  = var.kube_context
  }

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install argo-rollouts argo-rollouts \
        --repo https://argoproj.github.io/argo-helm \
        --version "${var.argo_rollouts_chart_version}" \
        --namespace argo-rollouts --create-namespace \
        --kube-context "${var.kube_context}" \
        --atomic --wait
    EOT
  }
}
