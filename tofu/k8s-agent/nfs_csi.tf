# The Octopus K8s Agent's persistent volume uses an NFS CSI driver. Without
# this, the tentacle pod sits forever in ContainerCreating waiting on PVC
# attach. Mirrors the install-k8s-agent.sh from octopus-ttc.
resource "helm_release" "nfs_csi_driver" {
  name      = "csi-driver-nfs"
  namespace = "kube-system"

  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = "v4.*"

  atomic = true
}
