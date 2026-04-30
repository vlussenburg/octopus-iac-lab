# Two tag sets describe the demo's tenant variations:
#   - mood: which kind of quotes the tenant prefers
#   - tier: free/pro/enterprise, drives replica count + watermark
# Tag references in tenant_tags use canonical "TagSetName/TagName" form.

resource "octopusdeploy_tag_set" "mood" {
  name        = "mood"
  description = "Quote curation theme. Tenant variable Featured.Mood is scoped against this."
  scopes      = ["Tenant"]
}

resource "octopusdeploy_tag" "mood_comedy" {
  name       = "comedy"
  color      = "#F5C518"
  tag_set_id = octopusdeploy_tag_set.mood.id
}

resource "octopusdeploy_tag" "mood_silicon_valley" {
  name       = "silicon-valley"
  color      = "#00B0FF"
  tag_set_id = octopusdeploy_tag_set.mood.id
}

resource "octopusdeploy_tag" "mood_stoic" {
  name       = "stoic"
  color      = "#7E57C2"
  tag_set_id = octopusdeploy_tag_set.mood.id
}

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

# Three tenants modeling fictional customers, each on a different tier and
# preferring a different mood. Tenant variables (Featured.Mood, Replicas,
# Branding.Watermark) live in .octopus/variables.ocl scoped by tenant tag.

resource "octopusdeploy_tenant" "acme_corp" {
  name        = "acme-corp"
  description = "Looney Tunes-flavoured megacorp. Enterprise tier, comedy mood."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_enterprise.name}",
    "${octopusdeploy_tag_set.mood.name}/${octopusdeploy_tag.mood_comedy.name}",
  ]
}

resource "octopusdeploy_tenant" "globex" {
  name        = "globex"
  description = "Hank Scorpio's tech empire. Pro tier, hustle mood."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_pro.name}",
    "${octopusdeploy_tag_set.mood.name}/${octopusdeploy_tag.mood_silicon_valley.name}",
  ]
}

resource "octopusdeploy_tenant" "initech" {
  name        = "initech"
  description = "Stapler-bound TPS pushers. Free tier, stoic mood."
  tenant_tags = [
    "${octopusdeploy_tag_set.app.name}/${octopusdeploy_tag.app_randomquotes.name}",
    "${octopusdeploy_tag_set.tier.name}/${octopusdeploy_tag.tier_free.name}",
    "${octopusdeploy_tag_set.mood.name}/${octopusdeploy_tag.mood_stoic.name}",
  ]
}
