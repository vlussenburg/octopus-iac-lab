# Local module — emulates a future `octopusdeploy_argocd_application` resource.
#
# The OctopusDeploy/octopusdeploy provider (v1.12.0 as of writing) ships zero
# Argo CD resources. Octopus's official IaC story for this is "use the helm
# provider for the Gateway and put scoping annotations on Application CRDs
# yourself." This module wraps that pattern in a clean interface so the call
# site reads like the resource we'd hope the provider eventually ships:
#
#   module "argocd_app" {
#     source                   = "../modules/octopus-argocd-application"
#     name                     = "randomquotes-acme-corp-dev"
#     octopus_project_slug     = "randomquotes"
#     octopus_environment_slug = "dev"
#     octopus_tenant_slug      = "acme-corp"
#     source_repo_url          = "https://github.com/vlussenburg/octopus-iac-lab"
#     source_path              = "app/k8s"
#     source_target_revision   = "HEAD"
#     destination_namespace    = "argo-randomquotes-acme-corp-dev"
#   }
#
# When (if) the provider gains an `octopusdeploy_argocd_application` resource,
# the migration is to swap the kubectl_manifest body out for the provider
# resource and keep the variable surface intact — that's why this module's
# inputs are deliberately named after Octopus concepts ("project_slug",
# "environment_slug", "tenant_slug"), not Argo / Kubernetes ones.
#
# References:
#   https://octopus.com/docs/argo-cd/annotations
#   https://octopus.com/docs/argo-cd/annotations/helm-annotations

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}

locals {
  # Octopus annotation keys (https://octopus.com/docs/argo-cd/annotations).
  # Suffix `.<source-name>` is omitted because we model single-source apps.
  octopus_annotations = merge(
    {
      "argo.octopus.com/project"     = var.octopus_project_slug
      "argo.octopus.com/environment" = var.octopus_environment_slug
    },
    var.octopus_tenant_slug == null ? {} : {
      "argo.octopus.com/tenant" = var.octopus_tenant_slug
    },
    var.image_replace_paths == null ? {} : {
      "argo.octopus.com/image-replace-paths" = var.image_replace_paths
    },
  )

  manifest = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name        = var.name
      namespace   = var.namespace
      annotations = merge(local.octopus_annotations, var.extra_annotations)
      labels      = var.labels
    }
    spec = {
      project = var.argocd_project
      source = {
        repoURL        = var.source_repo_url
        path           = var.source_path
        targetRevision = var.source_target_revision
      }
      destination = {
        server    = var.destination_server
        namespace = var.destination_namespace
      }
      syncPolicy = {
        automated = var.sync_automated ? {
          prune    = var.sync_prune
          selfHeal = var.sync_self_heal
        } : null
        syncOptions = compact([
          var.sync_create_namespace ? "CreateNamespace=true" : "",
        ])
      }
    }
  })
}

resource "kubectl_manifest" "application" {
  yaml_body = local.manifest

  # Apps live in argocd's namespace by convention; deletion of the Application
  # cascades to its created resources via Argo's finalizer (set by Argo itself
  # when the Application is created).
  server_side_apply = true
  force_conflicts   = true
}
