# nginx-ingress controller, cluster-wide infra. One controller serves every
# tenant's Ingress resource via Host header routing. Same idempotent
# `helm upgrade --install` pattern as the NFS CSI driver — multiple stacks
# can apply without coordination, destroy is a no-op.
#
# `controller.service.ports.http = 8080` so we don't fight port 80 with
# other LBs, and 8080 is the conventional dev-friendly high port. Browse
# any tenant at  http://<source>-<tenant>-<env>.localtest.me:8080.
# (`*.localtest.me` resolves to 127.0.0.1, so no /etc/hosts edits.)
resource "null_resource" "nginx_ingress" {
  triggers = {
    chart_version = var.nginx_ingress_chart_version
    kube_context  = var.kube_context
  }

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install ingress-nginx ingress-nginx \
        --repo https://kubernetes.github.io/ingress-nginx \
        --version "${var.nginx_ingress_chart_version}" \
        --namespace ingress-nginx --create-namespace \
        --kube-context "${var.kube_context}" \
        --set controller.service.type=LoadBalancer \
        --set controller.service.ports.http=8080 \
        --set controller.service.ports.https=8443 \
        --atomic --wait
    EOT
  }
}
