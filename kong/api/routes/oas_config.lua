-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local oas_config   = require "kong.enterprise_edition.oas_config"
local core_handler = require "kong.runloop.handler"
local singletons   = require "kong.singletons"
local uuid         = require("kong.tools.utils").uuid


local kong = kong


local function rebuild_routes()
  local old_ws = ngx.ctx.workspace
  ngx.ctx.workspace = nil
  core_handler.build_router(singletons.db, uuid())
  ngx.ctx.workspace = old_ws
end


return {
  ["/oas-config"] = {
    POST = function(self, dao, helpers)
      rebuild_routes()

      local res, err_t = oas_config.post_auto_config(self.params.spec)
      if err_t then
        return kong.response.exit(err_t.code, { message = err_t.message })
      end

      return kong.response.exit(201, res)
    end,

    PATCH = function(self, dao, helpers)
      local ok, err_t, res, resources_created = oas_config.patch_auto_config(self.params.spec, self.params.recreate_routes)
      if not ok then
        return kong.response.exit(err_t.code, { message = err_t.message })
      end

      if resources_created then
        return kong.response.exit(201, res)
      end

      return kong.response.exit(200, res)
    end,
  }
}