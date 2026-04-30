# Upload a brand-coloured PNG logo per tenant via the Octopus API. The
# provider's octopusdeploy_tenant resource doesn't expose a logo attribute,
# so we drop down to a curl POST against /api/{space}/tenants/{id}/logo.
# Octopus accepts PNG / JPG / GIF here; SVG is rejected with HTTP 400 even
# though the default placeholder logo is server-rendered SVG.

locals {
  tenant_logos = {
    acme-corp = {
      tenant_id = octopusdeploy_tenant.acme_corp.id
      file      = "${path.module}/../../assets/tenant-logos/acme-corp.png"
    }
    globex = {
      tenant_id = octopusdeploy_tenant.globex.id
      file      = "${path.module}/../../assets/tenant-logos/globex.png"
    }
    initech = {
      tenant_id = octopusdeploy_tenant.initech.id
      file      = "${path.module}/../../assets/tenant-logos/initech.png"
    }
  }
}

resource "null_resource" "tenant_logo" {
  for_each = local.tenant_logos

  triggers = {
    tenant_id   = each.value.tenant_id
    space_id    = data.terraform_remote_state.space.outputs.space_id
    octopus_url = var.octopus_url
    api_key     = var.octopus_api_key
    file_sha    = filesha256(each.value.file)
  }

  provisioner "local-exec" {
    # `set -e` matters: without it bash returns the exit code of the trailing
    # echo (always 0), masking a failed curl. The non-spaced URL silently
    # 404s on non-default Spaces, so this also pins the space prefix.
    command = <<-EOT
      set -e
      curl -sf -H "X-Octopus-ApiKey: ${self.triggers.api_key}" \
        -F "fileToUpload=@${each.value.file};type=image/png" \
        "${self.triggers.octopus_url}/api/${self.triggers.space_id}/tenants/${self.triggers.tenant_id}/logo" >/dev/null
      echo "uploaded logo for ${each.key}"
    EOT
  }
}
