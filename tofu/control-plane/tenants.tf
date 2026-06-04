# tier is the only tenant variation that's a genuine customer attribute (plan
# size — exists independent of any app), so it lives here as a tenant tag.
# mood is deliberately NOT here: a tenant has no mood until randomquotes is
# deployed, so it's a per-tenant randomquotes project variable, not tenant
# identity. See tofu/app-randomquotes/{project,tenant_variables}.tf.
# Tag references in tenant_tags use canonical "TagSetName/TagName" form.

resource "octopusdeploy_tag_set" "tier" {
  name        = "tier"
  description = "Plan size. Drives Replicas + Branding.Watermark variables."
  scopes      = ["Tenant"]
}

# Cohort tag — every tenant of a given app gets one. CI deploys to
# `tenant_tags: app/randomquotes` so it doesn't have to know the specific
# tenant names. Adding a tenant just means tagging it with `app/randomquotes`
# and the next pipeline picks it up.
resource "octopusdeploy_tag_set" "app" {
  name        = "app"
  description = "Which app a tenant participates in. Used by CI for tenant-tag-driven deploys."
  scopes      = ["Tenant"]
}

resource "octopusdeploy_tag" "app_randomquotes" {
  name       = "randomquotes"
  color      = "#E94560"
  tag_set_id = octopusdeploy_tag_set.app.id
}

resource "octopusdeploy_tag" "tier_free" {
  name       = "free"
  color      = "#9E9E9E"
  tag_set_id = octopusdeploy_tag_set.tier.id
}

resource "octopusdeploy_tag" "tier_pro" {
  name       = "pro"
  color      = "#42A5F5"
  tag_set_id = octopusdeploy_tag_set.tier.id
}

resource "octopusdeploy_tag" "tier_enterprise" {
  name       = "enterprise"
  color      = "#43A047"
  tag_set_id = octopusdeploy_tag_set.tier.id
}

# Fictional customer tenants, each on a different tier. Their randomquotes mood
# (and the icon/colour it drives) is a project variable per tenant, not a tag —
# see tofu/app-randomquotes/tenant_variables.tf.

resource "octopusdeploy_tenant" "acme_corp" {
  name        = "acme-corp"
  description = "Looney Tunes-flavoured megacorp. Enterprise tier."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_enterprise.name}",
  ]
}

resource "octopusdeploy_tenant" "globex" {
  name        = "globex"
  description = "Hank Scorpio's tech empire. Pro tier."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_pro.name}",
  ]
}

resource "octopusdeploy_tenant" "initech" {
  name        = "initech"
  description = "Stapler-bound TPS pushers. Free tier."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_free.name}",
  ]
}
