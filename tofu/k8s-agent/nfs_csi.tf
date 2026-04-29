# The Octopus K8s Agent's PVC needs the NFS CSI driver. The driver is
# cluster-wide infra (one DaemonSet per node), shared by every Octopus
# target that registers an agent against this cluster.
#
# `helm upgrade --install` is idempotent — installs if missing, upgrades if
# present, no-ops if already at the target version. That makes apply safe
# even when two stacks targeting different Octopus instances share the same
# K8s cluster. Destroy is intentionally a no-op: leave the shared driver
# running, since another agent on the cluster may still need it. Explicit
# cleanup lives in `make reset` or `helm uninstall csi-driver-nfs -n kube-system`.
resource "null_resource" "nfs_csi_driver" {
  triggers = {
    chart_version = var.nfs_csi_chart_version
    kube_context  = var.kube_context
  }

  provisioner "local-exec" {
    command = <<-EOT
      helm upgrade --install csi-driver-nfs csi-driver-nfs \
        --repo https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts \
        --version "${var.nfs_csi_chart_version}" \
        --namespace kube-system \
        --kube-context "${var.kube_context}" \
        --atomic --wait
    EOT
  }
}
