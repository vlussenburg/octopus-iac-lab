# Sealed Secrets controller (Bitnami) — cluster-wide infra alongside the
# NFS CSI driver and nginx-ingress. Same idempotent helm pattern: install
# survives `make destroy` and serves any agent / Argo on this cluster.
#
# Sealed Secrets lets us commit encrypted secrets to git. The controller
# holds a private key in the cluster and decrypts SealedSecret CRDs into
# regular k8s Secrets. Combined with `kubeseal --scope cluster-wide`, one
# sealed blob in the chart works for every tenant's destination namespace
# without per-namespace re-encryption.
resource "null_resource" "sealed_secrets" {
  triggers = {
    chart_version = var.sealed_secrets_chart_version
    kube_context  = var.kube_context
  }

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install sealed-secrets sealed-secrets \
        --repo https://bitnami-labs.github.io/sealed-secrets \
        --version "${var.sealed_secrets_chart_version}" \
        --namespace kube-system \
        --kube-context "${var.kube_context}" \
        --set fullnameOverride=sealed-secrets-controller \
        --atomic --wait
    EOT
  }
}
