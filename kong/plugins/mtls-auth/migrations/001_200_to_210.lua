local operations = require "kong.db.migrations.operations.200_to_210"

local plugin_entities = {
  {
    name = "mtls_auth_credentials",
    primary_key = "id",
    uniques = {"cache_key"},
    fks = {
      {name = "consumer", reference = "consumers", on_delete = "cascade"},
      -- ca_certificates is not workspaceable
      -- {name = "ca_certificate", reference = "ca_certificates", on_delete = "cascade"}
    }
  }
}

return operations.ws_migrate_plugin(plugin_entities)
