-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"


local function check_start(start)
  local time = math.floor(ngx.now())
  if start and start < time then
    return false, "'start' cannot be in the past"
  end

  return true
end

return {
  name = "canary",
  fields = {
    { consumer = typedefs.no_consumer },
    { config = {
        type = "record",
        shorthand_fields = {
          -- deprecated forms, to be removed in Kong 3.0
          { hash = {
            type = "string",
            func = function(value)
              if value == "whitelist" then
                value = "allow"
              elseif value == "blacklist" then
                value = "deny"
              end

              return { hash = value }
            end,
          }},
        },
        fields = {
          { start = {
              type = "number",
              custom_validator = check_start
          }},
          { hash = {
              type = "string",
              default = "consumer",
              one_of = { "consumer", "ip", "none", "allow", "deny" },
          }},
          { duration = {
              type = "number",
              default = 60 * 60,
              gt = 0
          }},
          { steps = {
              type = "number",
              default = 1000,
              gt = 1
          }},
          { percentage = {
              type = "number",
              between = { 0, 100 }
          }},
          { upstream_host = typedefs.host },
          { upstream_port = typedefs.port },
          { upstream_uri = {
              type = "string",
              len_min = 1
          }},
          { upstream_fallback = {
              type = "boolean",
              default = false,
              required = true
          }},
          { groups = {
              type = "array",
              elements = { type = "string" }
          }}
        }
    }}
  },
  entity_checks = {
    { at_least_one_of = { "config.upstream_uri", "config.upstream_host", "config.upstream_port" }},
    { conditional = {
        if_field = "config.upstream_fallback", if_match = { eq = true },
        then_field = "config.upstream_host", then_match = { required = true }
    }},
    { conditional_at_least_one_of = {
        if_field = "config.hash", if_match = { one_of = { "consumer", "ip", "none" }},
        then_at_least_one_of = { "config.percentage", "config.start" }
    }}
  }
}