# Upload a brand-coloured SVG logo per tenant via the Octopus API. The
# provider's octopusdeploy_tenant resource doesn't expose a logo attribute,
# so we drop down to a curl POST against /api/{space}/tenants/{id}/logo.
#
# Trigger keys include the file's sha256 — re-uploads only happen when the
# SVG content changes, so plan/apply is a no-op on subsequent runs.

locals {
  tenant_logos = {
    acme-corp = {
      tenant_id = octopusdeploy_tenant.acme_corp.id
      file      = "${path.module}/../../assets/tenant-logos/acme-corp.svg"
    }
    globex = {
      tenant_id = octopusdeploy_tenant.globex.id
      file      = "${path.module}/../../assets/tenant-logos/globex.svg"
    }
    initech = {
      tenant_id = octopusdeploy_tenant.initech.id
      file      = "${path.module}/../../assets/tenant-logos/initech.svg"
    }
  }
}

resource "null_resource" "tenant_logo" {
  for_each = local.tenant_logos

  triggers = {
    tenant_id   = each.value.tenant_id
    octopus_url = var.octopus_url
    api_key     = var.octopus_api_key
    file_sha    = filesha256(each.value.file)
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sf -H "X-Octopus-ApiKey: ${self.triggers.api_key}" \
        -F "fileToUpload=@${each.value.file};type=image/svg+xml" \
        "${self.triggers.octopus_url}/api/tenants/${self.triggers.tenant_id}/logo" >/dev/null
      echo "uploaded logo for ${each.key}"
    EOT
  }
}
