# Non-sensitive lab config — shared across both worktrees via this committed
# file. Sensitive values (octopus_url, octopus_api_key) come in via TF_VAR_*
# from the Makefile.

kube_context     = "docker-desktop"
argocd_namespace = "argocd"
ingress_host     = "argocd.localtest.me"

# argo-cd helm chart series. 7.x is the chart for ArgoCD 2.13.x.
argocd_chart_version = "7.7.*"

# Octopus Argo CD Gateway chart series.
gateway_chart_version = "1.23.*"
