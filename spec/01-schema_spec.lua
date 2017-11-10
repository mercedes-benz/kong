local validate_entity    = require("kong.dao.schemas_validation").validate_entity
local proxy_cache_schema = require "kong.plugins.proxy-cache.schema"

describe("proxy-cache schema", function()
  it("accepts a minimal config", function()
    local ok, err = validate_entity({
      strategy = "memory",
    }, proxy_cache_schema)

    assert.is_nil(err)
    assert.is_true(ok)
  end)

  it("accepts a config with custom values", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = { 200, 301 },
      request_method = { "GET" },
      content_type = { "application/json" },
    }, proxy_cache_schema)

    assert.is_nil(err)
    assert.is_true(ok)
  end)

  it("accepts an array of numbers as strings", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = {"123", "200"},
    }, proxy_cache_schema)

    assert.is_nil(err)
    assert.is_true(ok)
  end)

  it("errors with invalid response_code", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = { 99 },
    }, proxy_cache_schema)

    assert.same("response_code must be an integer within 100 - 999", err.response_code)
    assert.is_false(ok)
  end)

  it("errors if response_code is an empty array", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = {},
    }, proxy_cache_schema)

    assert.same("response_code must be an array of numbers", err.response_code)
    assert.is_false(ok)
  end)

  it("errors if response_code is a string", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = "",
    }, proxy_cache_schema)

    assert.same("response_code must be an array of numbers", err.response_code)
    assert.is_false(ok)
  end)

  it("errors if response_code has non-numeric values", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = {true, "alo", 123},
    }, proxy_cache_schema)

    assert.same("response_code must be an array of numbers", err.response_code)
    assert.is_false(ok)
  end)

  it("errors if response_code has float value", function()
    local ok, err = validate_entity({
      strategy = "memory",
      response_code = {123.5},
    }, proxy_cache_schema)

    assert.same("response_code must be an integer within 100 - 999", err.response_code)
    assert.is_false(ok)
  end)



  it("errors with invalid ttl", function()
    local ok, err = validate_entity({
      strategy = "memory",
      cache_ttl = -1
    }, proxy_cache_schema)

    assert.same("cache_ttl must be a positive number", err.cache_ttl)
    assert.is_false(ok)
  end)
end)
