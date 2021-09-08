package = "kong-plugin-enterprise-proxy-cache"
version = "0.5.6-0"

source = {
  url = "git://github.com/Kong/kong-plugin-enterprise-proxy-cache",
  tag = "0.5.6"
}

supported_platforms = {"linux", "macosx"}
description = {
  summary = "HTTP Proxy Caching for Kong Enterprise",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.proxy-cache-advanced.handler"]                             = "kong/plugins/enterprise_edition/proxy-cache-advanced/handler.lua",
    ["kong.plugins.proxy-cache-advanced.cache_key"]                           = "kong/plugins/enterprise_edition/proxy-cache-advanced/cache_key.lua",
    ["kong.plugins.proxy-cache-advanced.schema"]                              = "kong/plugins/enterprise_edition/proxy-cache-advanced/schema.lua",
    ["kong.plugins.proxy-cache-advanced.api"]                                 = "kong/plugins/enterprise_edition/proxy-cache-advanced/api.lua",
    ["kong.plugins.proxy-cache-advanced.strategies"]                          = "kong/plugins/enterprise_edition/proxy-cache-advanced/strategies/init.lua",
    ["kong.plugins.proxy-cache-advanced.strategies.memory"]                   = "kong/plugins/enterprise_edition/proxy-cache-advanced/strategies/memory.lua",
    ["kong.plugins.proxy-cache-advanced.strategies.redis"]                    = "kong/plugins/enterprise_edition/proxy-cache-advanced/strategies/redis.lua",
    ["kong.plugins.proxy-cache-advanced.migrations"]                          = "kong/plugins/enterprise_edition/proxy-cache-advanced/migrations/init.lua",
    ["kong.plugins.proxy-cache-advanced.migrations.001_035_to_050"]           = "kong/plugins/enterprise_edition/proxy-cache-advanced/migrations/001_035_to_050.lua",
  }
}