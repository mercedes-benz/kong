local cjson = require "cjson"
local inspect = require "inspect"

local upgrade_helpers = require "spec/upgrade_helpers"

local HEADERS = { ["Content-Type"] = "application/json" }

describe("database migration", function()
    upgrade_helpers.it_when("old_after_up", "has created the expected new columns", function()
        assert.table_has_column("targets", "cache_key", "text")
        assert.table_has_column("upstreams", "hash_on_query_arg", "text")
        assert.table_has_column("upstreams", "hash_fallback_query_arg", "text")
        assert.table_has_column("upstreams", "hash_on_uri_capture", "text")
        assert.table_has_column("upstreams", "hash_fallback_uri_capture", "text")
    end)
end)

describe("vault related data migration", function()

    lazy_setup(upgrade_helpers.start_kong)
    lazy_teardown(upgrade_helpers.stop_kong)

    local function assert_no_entities(resource)
      return function()
        local admin_client = upgrade_helpers.admin_client()
        local res = admin_client:get(resource)
        admin_client:close()
        assert.equal(200, res.status)
        local body = res:read_body()
        if body then
          local json = cjson.decode(body)
          assert.equal(0, #json.data)
        end
      end
    end

    upgrade_helpers.it_when("old_before", "has no vaults", assert_no_entities("/vaults-beta"))
    upgrade_helpers.it_when("new_after_finish", "has no vault", assert_no_entities("/vaults"))
end)
