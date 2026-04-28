resource "octopusdeploy_environment" "dev" {
  name                         = "Dev"
  description                  = "Development environment"
  use_guided_failure           = false
  allow_dynamic_infrastructure = true
}

resource "octopusdeploy_environment" "production" {
  name                         = "Production"
  description                  = "Production environment"
  use_guided_failure           = true
  allow_dynamic_infrastructure = true
}
