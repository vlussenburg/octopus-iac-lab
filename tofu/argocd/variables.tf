variable "octopus_url" {
  description = "Octopus Server URL (HTTP API), as seen from the host where tofu runs. Used by the octopusdeploy provider. Self-host: http://localhost:8090; SaaS: https://<id>.octopus.app."
  type        = string
}

variable "octopus_url_from_cluster" {
  description = "Octopus Server URL as seen from inside the K8s cluster — the registration pod uses this. Defaults match Docker Desktop K8s: localhost on the host = host.docker.internal in the pod. SaaS: same as octopus_url (public URL is reachable from the cluster too)."
  type        = string
  default     = "http://host.docker.internal:8090"
}

variable "octopus_api_key" {
  description = "Octopus API key. Used both by the provider and by the Gateway's registration init job."
  type        = string
  sensitive   = true
}

variable "octopus_grpc_url" {
  description = "Optional override for the Octopus gRPC URL the Gateway dials. By default derived from octopus_url: SaaS hits <id>.octopus.app:443 (TLS over public cert), self-host hits host.docker.internal:8443. Self-host's :8443 is TLS with a self-signed cert; the Gateway will reject it unless `gateway.serverCertificateSecretName` is wired in. SaaS works out of the box."
  type        = string
  default     = null
}

variable "octopus_grpc_plaintext" {
  description = "If true, the Gateway skips TLS on the Octopus gRPC connection. Useful if you have a separate plaintext-tunnel terminating proxy. Default false."
  type        = bool
  default     = false
}

variable "kube_context" {
  description = "kubeconfig context for the cluster. Defaults to docker-desktop."
  type        = string
  default     = "docker-desktop"
}

variable "argocd_chart_version" {
  description = "argo-cd helm chart version. https://github.com/argoproj/argo-helm/releases."
  type        = string
  default     = "7.7.*"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD installs into."
  type        = string
  default     = "argocd"
}

variable "gateway_chart_version" {
  description = "Octopus Argo CD Gateway chart version. Latest 1.x as of 2026-04 is 1.23.x."
  type        = string
  default     = "1.23.*"
}

variable "ingress_host" {
  description = "Hostname the Argo UI is reachable at via the cluster's nginx-ingress controller. *.localtest.me resolves to 127.0.0.1."
  type        = string
  default     = "argocd.localtest.me"
}
