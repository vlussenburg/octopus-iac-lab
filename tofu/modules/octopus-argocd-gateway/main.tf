# Local module — placeholder for a future `octopusdeploy_argocd_gateway`
# provider resource.
#
# The OctopusDeploy/octopusdeploy provider (v1.12.0 as of writing) ships zero
# Argo CD resources. Octopus's IaC story for the Gateway is "use the helm
# provider to install the chart, register the Octopus side imperatively, and
# clean up via the API on destroy." This module wraps that whole pattern in
# a clean interface so the call site reads like the resource we'd hope the
# provider eventually ships:
#
#   module "argocd_gateway" {
#     source              = "../modules/octopus-argocd-gateway"
#     name                = "argocd-local"
#     octopus_url         = "http://localhost:8090"
#     octopus_url_from_cluster = "http://host.docker.internal:8090"
#     octopus_grpc_url    = "grpc://host.docker.internal:8443"
#     octopus_api_key     = var.octopus_api_key
#     octopus_space_id    = data.terraform_remote_state.space.outputs.space_id
#     environments        = ["Dev", "Production"]
#     argocd_namespace    = "argocd"
#     argocd_jwt          = argocd_account_token.octopus.jwt
#     web_ui_url          = "http://argocd.localtest.me:8080"
#   }
#
# When (if) the provider gains an `octopusdeploy_argocd_gateway` resource,
# the migration is mechanical: swap the helm_release + secrets + null_resource
# guts for the provider resource and keep the variable surface intact —
# inputs are deliberately Octopus-flavoured ("octopus_space_id",
# "environments", "name") rather than helm-flavoured ("chart_version",
# "values").

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# --- per-Octopus namespace + secrets ----------------------------------------

resource "kubernetes_namespace_v1" "this" {
  metadata {
    # Suffix the gateway's namespace with the Octopus name so multiple
    # gateways can share a cluster. The chart's defaults assume a unique
    # namespace per gateway anyway.
    name = "octopus-argo-gateway-${var.name}"
  }
}

# Octopus access token Secret — referenced by the chart so the registration
# init Job can call Octopus's HTTP API to create an ArgoCDGateways-N record.
resource "kubernetes_secret_v1" "octopus_access_token" {
  metadata {
    name      = "octopus-access-token"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    OCTOPUS_SERVER_ACCESS_TOKEN = var.octopus_api_key
  }
}

# Argo CD JWT Secret — referenced by the chart so the running Gateway pod
# can authenticate to argocd-server's gRPC.
resource "kubernetes_secret_v1" "argocd_token" {
  metadata {
    name      = "argocd-octopus-token"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    ARGOCD_AUTH_TOKEN = var.argocd_jwt
  }
}

# --- helm release ----------------------------------------------------------

resource "helm_release" "this" {
  name             = "octopus-argo-gateway-${var.name}"
  namespace        = kubernetes_namespace_v1.this.metadata[0].name
  create_namespace = false

  repository = "oci://registry-1.docker.io/octopusdeploy"
  chart      = "octopus-argocd-gateway-chart"
  version    = var.chart_version

  atomic = true
  wait   = true

  # --- registration: Gateway → Octopus HTTP API (one-shot init Job) -------

  set {
    name  = "registration.octopus.name"
    value = var.name
  }

  # The registration Job runs INSIDE the cluster, so this is the from-cluster
  # URL — host.docker.internal:8090 for self-host, the public URL for SaaS.
  set {
    name  = "registration.octopus.serverApiUrl"
    value = var.octopus_url_from_cluster
  }

  set {
    name  = "registration.octopus.spaceId"
    value = var.octopus_space_id
  }

  set_list {
    name  = "registration.octopus.environments"
    value = var.environments
  }

  set {
    name  = "registration.octopus.serverAccessTokenSecretName"
    value = kubernetes_secret_v1.octopus_access_token.metadata[0].name
  }

  set {
    name  = "registration.octopus.serverAccessTokenSecretKey"
    value = "OCTOPUS_SERVER_ACCESS_TOKEN"
  }

  set {
    name  = "registration.argocd.webUiUrl"
    value = var.web_ui_url
  }

  # --- runtime: Gateway → Octopus over gRPC --------------------------------

  set {
    name  = "gateway.octopus.serverGrpcUrl"
    value = var.octopus_grpc_url
  }

  set {
    name  = "gateway.octopus.plaintext"
    value = var.octopus_grpc_plaintext ? "true" : "false"
  }

  # --- runtime: Gateway → ArgoCD over gRPC ---------------------------------

  set {
    name  = "gateway.argocd.serverGrpcUrl"
    value = "grpc://argocd-server.${var.argocd_namespace}.svc.cluster.local:443"
  }

  set {
    name  = "gateway.argocd.plaintext"
    value = "true"
  }

  set {
    name  = "gateway.argocd.authenticationTokenSecretName"
    value = kubernetes_secret_v1.argocd_token.metadata[0].name
  }

  set {
    name  = "gateway.argocd.authenticationTokenSecretKey"
    value = "ARGOCD_AUTH_TOKEN"
  }

  # --- chart-level toggles --------------------------------------------------

  # The chart ships a daily auto-update CronJob. Disable it: the module
  # owns the chart version, and an out-of-band update would fight tofu.
  set {
    name  = "autoUpdate.enabled"
    value = "false"
  }
}

# --- destroy-time deregistration -------------------------------------------

# Provider-gap pattern. Octopus's `POST /api/{space}/argocdgateways` is
# one-way: a `helm uninstall` alone leaves an orphan record that refuses
# every subsequent re-install ("An ArgoCDGateway with this name already
# exists."). We close the loop here. Disappears when the provider ships
# the real resource.
resource "null_resource" "deregister" {
  triggers = {
    octopus_url     = var.octopus_url
    octopus_api_key = var.octopus_api_key
    space_id        = var.octopus_space_id
    name            = var.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      ID=""
      for i in $(seq 1 50); do
        NAME=$(curl -sf -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/argocdgateways/ArgoCDGateways-$i" \
          2>/dev/null | jq -r '.Resource.Name // empty')
        if [ "$NAME" = "${self.triggers.name}" ]; then
          ID="ArgoCDGateways-$i"
          break
        fi
      done
      if [ -n "$ID" ]; then
        curl -sf -X DELETE -H "X-Octopus-ApiKey: ${self.triggers.octopus_api_key}" \
          "${self.triggers.octopus_url}/api/${self.triggers.space_id}/argocdgateways/$ID" >/dev/null
        echo "Deregistered ${self.triggers.name} ($ID)"
      else
        echo "No registration found for ${self.triggers.name} — already gone"
      fi
    EOT
  }

  depends_on = [helm_release.this]
}
