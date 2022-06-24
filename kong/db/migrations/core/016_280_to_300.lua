local log = require "kong.cmd.utils.log"
local arrays = require "pgmoon.arrays"

local fmt          = string.format
local assert       = assert
local ipairs       = ipairs
local cassandra    = require "cassandra"
local find         = string.find
local upper        = string.upper
local re_find      = ngx.re.find
local encode_array = arrays.encode_array


-- remove repeated targets, the older ones are not useful anymore. targets with
-- weight 0 will be kept, as we cannot tell which were deleted and which were
-- explicitly set as 0.
local function c_remove_unused_targets(coordinator)
  local upstream_targets = {}
  for rows, err in coordinator:iterate("SELECT id, upstream_id, target, created_at FROM targets") do
    if err then
      return nil, err
    end

    for _, row in ipairs(rows) do
      local key = fmt("%s:%s", row.upstream_id, row.target)

      if not upstream_targets[key] then
        upstream_targets[key] = {
          id = row.id,
          created_at = row.created_at,
        }
      else
        local to_remove
        if row.created_at > upstream_targets[key].created_at then
          to_remove = upstream_targets[key].id
          upstream_targets[key] = {
            id = row.id,
            created_at = row.created_at,
          }
        else
          to_remove = row.id
        end
        local _, err = coordinator:execute("DELETE FROM targets WHERE id = ?", {
          cassandra.uuid(to_remove)
        })

        if err then
          return nil, err
        end
      end
    end
  end

  return true
end


-- update cache_key for targets
local function c_update_target_cache_key(coordinator)
  for rows, err in coordinator:iterate("SELECT id, upstream_id, target, ws_id FROM targets") do
    if err then
      return nil, err
    end

    for _, row in ipairs(rows) do
      local cache_key = fmt("targets:%s:%s::::%s", row.upstream_id, row.target, row.ws_id)

      local _, err = coordinator:execute("UPDATE targets SET cache_key = ? WHERE id = ? IF EXISTS", {
        cache_key, cassandra.uuid(row.id)
      })

      if err then
        return nil, err
      end
    end
  end

  return true
end


local function c_copy_vaults_to_vault_auth_vaults(coordinator)
  for rows, err in coordinator:iterate("SELECT id, created_at, updated_at, name, protocol, host, port, mount, vault_token FROM vaults") do
    if err then
      log.warn("ignored error while running '016_280_to_300' migration: " .. err)
      break
    end

    for _, row in ipairs(rows) do
      local _, err = coordinator:execute(
        "INSERT INTO vault_auth_vaults (id, created_at, updated_at, name, protocol, host, port, mount, vault_token) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        cassandra.uuid(row.id),
        cassandra.timestamp(row.created_at),
        cassandra.timestamp(row.updated_at),
        cassandra.text(row.name),
        cassandra.text(row.protocol),
        cassandra.text(row.host),
        cassandra.int(row.port),
        cassandra.text(row.mount),
        cassandra.text(row.vault_token)
      )
      if err then
        return nil, err
      end
    end
  end

  return true
end


local function c_drop_vaults(connector, coordinator)
  local _, err = coordinator:execute("SELECT id, created_at, updated_at, name, protocol, host, port, mount, vault_token FROM vaults LIMIT 1")
  if not err then
    local ok
    ok, err = coordinator:execute("DROP TABLE IF EXISTS vaults");
    if not ok then
      return nil, err
    end

    ok, err = connector:wait_for_schema_consensus()
    if not ok then
      return nil, err
    end

  else
    log.warn("ignored error while running '016_280_to_300' migration: " .. err)
  end

  return true
end


local function c_create_vaults(connector, coordinator)
  local _, err = coordinator:execute("SELECT id, ws_id, prefix, name, description, config, created_at, updated_at, tags FROM vaults LIMIT 1")
  if err then
    log.warn("ignored error while running '016_280_to_300' migration: " .. err)

    local ok
    ok, err = coordinator:execute([[
    CREATE TABLE IF NOT EXISTS vaults (
      id          uuid,
      ws_id       uuid,
      prefix      text,
      name        text,
      description text,
      config      text,
      created_at  timestamp,
      updated_at  timestamp,
      tags        set<text>,
      PRIMARY KEY (id)
    )]]);
    if not ok then
      return nil, err
    end

    ok, err = coordinator:execute("CREATE INDEX IF NOT EXISTS vaults_prefix_idx ON vaults (prefix)")
    if not ok then
      return nil, err
    end

    ok, err = coordinator:execute("CREATE INDEX IF NOT EXISTS vaults_ws_id_idx  ON vaults (ws_id)")
    if not ok then
      return nil, err
    end

    ok, err = connector:wait_for_schema_consensus()
    if not ok then
      return nil, err
    end
  end

  return true
end


local function c_drop_vaults_beta(coordinator)
  local ok, err = coordinator:execute("DROP TABLE IF EXISTS vaults_beta");
  if not ok then
    return nil, err
  end

  return true
end

-- We do not percent decode route.path after 3.0, so here we do 1 last time for them
local normalize_regex
do
  local RESERVED_CHARACTERS = {
    [0x21] = true, -- !
    [0x23] = true, -- #
    [0x24] = true, -- $
    [0x25] = true, -- %
    [0x26] = true, -- &
    [0x27] = true, -- '
    [0x28] = true, -- (
    [0x29] = true, -- )
    [0x2A] = true, -- *
    [0x2B] = true, -- +
    [0x2C] = true, -- ,
    [0x2F] = true, -- /
    [0x3A] = true, -- :
    [0x3B] = true, -- ;
    [0x3D] = true, -- =
    [0x3F] = true, -- ?
    [0x40] = true, -- @
    [0x5B] = true, -- [
    [0x5D] = true, -- ]
  }
  local REGEX_META_CHARACTERS = {
    [0x2E] = true, -- .
    [0x5E] = true, -- ^
    -- $ in RESERVED_CHARACTERS
    -- * in RESERVED_CHARACTERS
    -- + in RESERVED_CHARACTERS
    [0x2D] = true, -- -
    -- ? in RESERVED_CHARACTERS
    -- ( in RESERVED_CHARACTERS
    -- ) in RESERVED_CHARACTERS
    -- [ in RESERVED_CHARACTERS
    -- ] in RESERVED_CHARACTERS
    [0x7B] = true, -- {
    [0x7D] = true, -- }
    [0x5C] = true, -- \
    [0x7C] = true, -- |
  }
  local ngx_re_gsub = ngx.re.gsub
  local string_char = string.char

  local function percent_decode(m)
    local hex = m[1]
    local num = tonumber(hex, 16)
    if RESERVED_CHARACTERS[num] then
      return upper(m[0])
    end

    local chr = string_char(num)
    if REGEX_META_CHARACTERS[num] then
      return "\\" .. chr
    end

    return chr
  end

  function normalize_regex(regex)
    if find(regex, "%", 1, true) then
      -- Decoding percent-encoded triplets of unreserved characters
      return ngx_re_gsub(regex, "%([\\dA-F]{2})", percent_decode, "joi")
    end
    return regex
  end
end

local function is_not_regex(path)
  return (re_find(path, [[[a-zA-Z0-9\.\-_~/%]*$]], "ajo"))
end

local function migrate_regex(reg)
  local normalized = normalize_regex(reg)
  return "~" .. normalized
end

local function c_migrate_regex_path(coordinator)
  for rows, err in coordinator:iterate("SELECT id, paths FROM routes") do
    if err then
      return nil, err
    end

    for i = 1, #rows do
      local route = rows[i]

      if not route.paths then
        goto continue
      end

      local changed = false
      for j, path in ipairs(route.paths) do
        if not is_not_regex(path) then
          local migrated_path = migrate_regex(path)
          if migrated_path ~= path then
            changed = true
            route.paths[j] = migrated_path
          end
        end
      end

      if changed then
        local _, err = coordinator:execute(
          "UPDATE routes SET paths = ? WHERE partition = 'routes' AND id = ?",
          { cassandra.list(route.paths), cassandra.uuid(route.id) }
        )
        if err then
          return nil, err
        end
      end
      ::continue::
    end
  end
  return true
end

local function render(template, keys)
  return (template:gsub("$%(([A-Z_]+)%)", keys))
end

local function p_migrate_regex_path(connector)
  for route, err in connector:iterate("SELECT id, paths FROM routes WHERE paths IS NOT NULL") do
    if err then
      return nil, err
    end

    local changed = false
    for i, path in ipairs(route.paths) do
      if is_not_regex(path) then
        goto continue
      end

      local normalized_path = migrate_regex(path)
      if normalized_path ~= path then
        changed = true
        route.paths[i] = normalized_path
      end
      ::continue::
    end

    if changed then
      local sql = render(
        "UPDATE routes SET paths = $(NORMALIZED_PATH) WHERE id = '$(ID)'", {
        NORMALIZED_PATH = encode_array(route.paths),
        ID = route.id,
      })

      local _, err = connector:query(sql)
      if err then
        return nil, err
      end
    end
  end

  return true
end

local function p_update_cache_key(connector)
  local _, err = connector:query([[
    DELETE FROM targets t1
          USING targets t2
          WHERE t1.created_at < t2.created_at
            AND t1.upstream_id = t2.upstream_id
            AND t1.target = t2.target;
    UPDATE targets SET cache_key = CONCAT('targets:', upstream_id, ':', target, '::::', ws_id);
    ]])

  if err then
    return nil, err
  end

  return true
end

local function ensure_empty_vaults_tables(connector)
  local ensure_table_is_empty = function (table)
    local res, err = connector:query("SELECT * FROM " .. table)
    if err then
      -- Assume that the error is about the missing table, which is OK
      return true
    end
    if #res > 0 then
      return nil, "Cannot perform database upgrade with data in " .. table .. " table.  Please delete all rows from it and retry"
    end
  end

  local res, err = ensure_table_is_empty("vaults_beta")
  if err then
    return nil, err
  end
  local res, err = ensure_table_is_empty("vaults")
  if err then
    return nil, err
  end
end

return {
  postgres = {
    up = [[
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "targets" ADD COLUMN "cache_key" TEXT UNIQUE;
        EXCEPTION WHEN duplicate_column THEN
          -- Do nothing, accept existing state
        END;
      $$;

      -- add new hash_on_query_arg field to upstreams
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "upstreams" ADD "hash_on_query_arg" TEXT;
        EXCEPTION WHEN DUPLICATE_COLUMN THEN
          -- Do nothing, accept existing state
        END;
      $$;

      -- add new hash_fallback_query_arg field to upstreams
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "upstreams" ADD "hash_fallback_query_arg" TEXT;
        EXCEPTION WHEN DUPLICATE_COLUMN THEN
          -- Do nothing, accept existing state
        END;
      $$;

      -- add new hash_on_uri_capture field to upstreams
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "upstreams" ADD "hash_on_uri_capture" TEXT;
        EXCEPTION WHEN DUPLICATE_COLUMN THEN
          -- Do nothing, accept existing state
        END;
      $$;

      -- add new hash_fallback_uri_capture field to upstreams
      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "upstreams" ADD "hash_fallback_uri_capture" TEXT;
        EXCEPTION WHEN DUPLICATE_COLUMN THEN
          -- Do nothing, accept existing state
        END;
      $$;

      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "routes" ADD COLUMN "atc" TEXT;
        EXCEPTION WHEN duplicate_column THEN
          -- Do nothing, accept existing state
        END;
      $$;

      DO $$
        BEGIN
          ALTER TABLE IF EXISTS ONLY "routes" ADD COLUMN "priority" BIGINT;
        EXCEPTION WHEN duplicate_column THEN
          -- Do nothing, accept existing state
        END;
      $$;
    ]],
    up_f = function(connector)

      local res, err = ensure_empty_vaults_tables(connector)
      if err then
        return nil, err
      end

      local _, err = connector:query([[
      DO $$
      BEGIN
        -- we only want to run this migration if there is vaults_beta table
        IF (SELECT to_regclass('vaults_beta')) IS NOT NULL THEN
          DROP TRIGGER IF EXISTS "vaults_beta_sync_tags_trigger" ON "vaults_beta";

          -- Enterprise Edition has a Vaults table created by a Vault Auth Plugin
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME TO "vault_auth_vaults";
          ALTER TABLE IF EXISTS ONLY "vault_auth_vaults" RENAME CONSTRAINT "vaults_pkey" TO "vault_auth_vaults_pkey";
          ALTER TABLE IF EXISTS ONLY "vault_auth_vaults" RENAME CONSTRAINT "vaults_name_key" TO "vault_auth_vaults_name_key";

          ALTER TABLE IF EXISTS ONLY "vaults_beta" RENAME TO "vaults";
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME CONSTRAINT "vaults_beta_pkey" TO "vaults_pkey";
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME CONSTRAINT "vaults_beta_id_ws_id_key" TO "vaults_id_ws_id_key";
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME CONSTRAINT "vaults_beta_prefix_key" TO "vaults_prefix_key";
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME CONSTRAINT "vaults_beta_prefix_ws_id_key" TO "vaults_prefix_ws_id_key";
          ALTER TABLE IF EXISTS ONLY "vaults" RENAME CONSTRAINT "vaults_beta_ws_id_fkey" TO "vaults_ws_id_fkey";

          ALTER INDEX IF EXISTS "vaults_beta_tags_idx" RENAME TO "vaults_tags_idx";

          BEGIN
            CREATE TRIGGER "vaults_sync_tags_trigger"
            AFTER INSERT OR UPDATE OF "tags" OR DELETE ON "vaults"
            FOR EACH ROW
            EXECUTE PROCEDURE sync_tags();
          EXCEPTION WHEN UNDEFINED_COLUMN OR UNDEFINED_TABLE THEN
            -- Do nothing, accept existing state
          END;
        END IF;
      END$$;
      ]])
      if err then
        return nil, err
      end

      return true
    end,
    teardown = function(connector)
      local _, err = p_update_cache_key(connector)
      if err then
        return nil, err
      end

      _, err = p_migrate_regex_path(connector)
      if err then
        return nil, err
      end

      return true
    end
  },

  cassandra = {
    up = [[
      CREATE TABLE IF NOT EXISTS vault_auth_vaults (
        id          uuid,
        created_at  timestamp,
        updated_at  timestamp,
        name        text,
        protocol    text,
        host        text,
        port        int,
        mount       text,
        vault_token text,
        PRIMARY KEY (id)
      );

      ALTER TABLE targets ADD cache_key text;
      CREATE INDEX IF NOT EXISTS targets_cache_key_idx ON targets(cache_key);

      -- add new hash_on_query_arg field to upstreams
      ALTER TABLE upstreams ADD hash_on_query_arg text;

      -- add new hash_fallback_query_arg field to upstreams
      ALTER TABLE upstreams ADD hash_fallback_query_arg text;

      -- add new hash_on_uri_capture field to upstreams
      ALTER TABLE upstreams ADD hash_on_uri_capture text;

      -- add new hash_fallback_uri_capture field to upstreams
      ALTER TABLE upstreams ADD hash_fallback_uri_capture text;

      ALTER TABLE routes ADD atc text;
      ALTER TABLE routes ADD priority int;
    ]],

    up_f = function(connector)
      local res, err = ensure_empty_vaults_tables(connector)
      if err then
        return nil, err
      end
    end,

    teardown = function(connector)

      local coordinator = assert(connector:get_stored_connection())
      local _, err = c_remove_unused_targets(coordinator)
      if err then
        return nil, err
      end

      _, err = c_update_target_cache_key(coordinator)
      if err then
        return nil, err
      end

      _, err = c_copy_vaults_to_vault_auth_vaults(coordinator)
      if err then
        return nil, err
      end

      _, err = c_drop_vaults(connector, coordinator)
      if err then
        return nil, err
      end

      _, err = c_drop_vaults_beta(coordinator)
      if err then
        return nil, err
      end

      _, err = c_create_vaults(connector, coordinator)
      if err then
        return nil, err
      end

      _, err = c_migrate_regex_path(coordinator)
      if err then
        return nil, err
      end

      return true
    end
  },
}
