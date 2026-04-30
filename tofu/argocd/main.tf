# ArgoCD + Octopus Argo CD Gateway, plus a sample annotated Application per
# tenant×env. Demonstrates Octopus's pull-based GitOps integration model
# (Octopus annotations on Argo Applications, Gateway watches the cluster +
# dials home over gRPC) alongside the existing push-based K8s agent.
#
# Two distinct tokens are involved:
#   - Octopus API key — used by the Gateway's registration init Job to
#     create an "Argo CD Instance" record in Octopus, and by the Gateway
#     pod to authenticate its outbound gRPC.
#   - Argo CD JWT — minted here for the `octopus` account in Argo (apiKey
#     capability), used by the Gateway pod to talk to argocd-server.
#
# Provider dependency note: the `argocd` provider has to authenticate to
# argocd-server, which doesn't exist until the argocd helm release applies.
# We solve that by using its `port_forward` mode + reading the auto-generated
# admin password from `argocd-initial-admin-secret`. The argocd provider
# only configures lazily when an `argocd_*` resource is read.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    octopusdeploy = {
      source  = "OctopusDeploy/octopusdeploy"
      version = "~> 1.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    argocd = {
      source  = "oboukili/argocd"
      version = "~> 6.1"
    }
    # null is used by the gateway module's destroy-time deregister.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "octopusdeploy" {
  address  = var.octopus_url
  api_key  = var.octopus_api_key
  space_id = data.terraform_remote_state.space.outputs.space_id
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = var.kube_context
  }
}

# Port-forwards to argocd-server itself; no host-side port forward needed.
# Authenticates with the auto-generated admin password from the standard
# argocd-initial-admin-secret. We read it via a kubernetes data source.
provider "argocd" {
  port_forward_with_namespace = local.argocd_namespace_name
  username                    = "admin"
  password                    = data.kubernetes_secret_v1.argocd_admin_initial.data["password"]
  insecure                    = true
  # argocd-server runs HTTP-only (configs.params.server.insecure=true in
  # argocd_install.tf) — the provider needs to dial it without TLS, otherwise
  # the handshake on port 443 fails with "connection refused".
  plain_text = true

  # v6 schema: flat `config_path` for kubeconfig path, nested `kubernetes`
  # block for context selection.
  config_path = "~/.kube/config"
  kubernetes {
    config_context = var.kube_context
  }
}

# Default `install_argocd` derives from worktree kind: local owns the install,
# saas piggybacks. Override per-stack with TF_VAR_install_argocd=true|false.
# `argocd_namespace_name` is a plain string so callers downstream don't have
# to conditionally reference `kubernetes_namespace_v1.argocd[0]` vs nothing.
locals {
  is_saas               = strcontains(var.octopus_url, "octopus.app")
  install_argocd_final  = coalesce(var.install_argocd, !local.is_saas)
  argocd_namespace_name = var.argocd_namespace
  target_kind           = local.is_saas ? "saas" : "local"
}

# --- cross-stack reads ------------------------------------------------------

data "terraform_remote_state" "space" {
  backend = "local"
  config = {
    path = "../space/terraform.tfstate"
  }
}

data "terraform_remote_state" "control_plane" {
  backend = "local"
  config = {
    path = "../control-plane/terraform.tfstate"
  }
}

# app-randomquotes' state isn't read directly today (the project slug is
# hardcoded as `randomquotes`), but we keep this remote_state in scope so
# the call site stays the natural place to wire `octopus_project_slug`
# from the app stack output if/when it grows one.
data "terraform_remote_state" "app" {
  backend = "local"
  config = {
    path = "../app-randomquotes/terraform.tfstate"
  }
}
