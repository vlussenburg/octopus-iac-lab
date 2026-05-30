# Look up the ServiceNow ITSM connection's Octopus-generated ID after the
# null_resource has PUT it. The provider has no data source for this yet,
# so we shell out — read-only call, idempotent. data "external" passes
# `query` as a JSON object on stdin to the program.
data "external" "snow_connection" {
  depends_on = [null_resource.servicenow_connection]

  program = ["bash", "-c", <<-EOT
    in=$(cat)
    url=$(echo "$in"  | jq -r '.octo_url')
    key=$(echo "$in"  | jq -r '.octo_key')
    name=$(echo "$in" | jq -r '.conn_name')
    response=$(curl -s -H "X-Octopus-ApiKey: $key" "$url/api/configuration/servicenow-integration/values")
    id=$(echo "$response" | jq -r --arg n "$name" '.Connections[] | select(.ConnectionName == $n) | .Id')
    if [ -z "$id" ] || [ "$id" = "null" ]; then
      echo "could not find ServiceNow connection named '$name'" >&2
      exit 1
    fi
    jq -n --arg id "$id" '{id: $id}'
  EOT
  ]

  query = {
    octo_url  = var.octopus_url
    octo_key  = var.octopus_api_key
    conn_name = var.connection_name
  }
}
