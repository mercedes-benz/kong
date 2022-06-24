
local cjson = require "cjson"

local upgrade_helpers = require "spec/upgrade_helpers"

describe("pre-function plugin migration", function()

    lazy_setup(upgrade_helpers.start_kong)
    lazy_teardown(upgrade_helpers.stop_kong)

    local custom_header_name = "X-Test-Header"
    local custom_header_content = "this is it"

    upgrade_helpers.setup(function ()
        local admin_client = upgrade_helpers.admin_client()
        local res = assert(admin_client:send {
            method = "POST",
            path = "/plugins/",
            body = {
              name = "pre-function",
              config = {
                functions = {
                  "kong.response.set_header('" .. custom_header_name .. "', '" .. custom_header_content .. "')"
                }
              }
            },
            headers = {
              ["Content-Type"] = "application/json"
            }
        })
        assert.res_status(201, res)
        admin_client:close()

        upgrade_helpers.create_example_service()
    end)

    upgrade_helpers.it_when("all_phases", "expected log header is added", function ()
        local res, body = upgrade_helpers.send_proxy_get_request()

        -- verify that HTTP response has had the header added by the plugin
        assert.equal(custom_header_content, res.headers[custom_header_name])
    end)
end)

