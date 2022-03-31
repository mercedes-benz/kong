-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

-- License cycle
--
-- The license is put in the global kong.license if it exists.  All
-- kong code assumes what is in kong.license is the license that was
-- in the system when kong started.
--
-- get_license_string fetches the license from ENV or FILE. It should
-- be called once (or very carfully) due to it migth be fetching a
-- tampered LICENSE FILE (in case the user modified after kong
-- started).


local cjson          = require "cjson.safe"
local pl_path        = require "pl.path"
local log            = require "kong.cmd.utils.log"
local dist_constants = require "kong.enterprise_edition.distributions_constants"
local license_utils  = require "kong.enterprise_edition.license_utils"


local timer_at = ngx.timer.at
local split = require('kong.tools.utils').split
local re_find = ngx.re.find
local kong_dict = ngx.shared.kong
local DAY = 24 * 3600
local WARNING_NOTICE_DAYS = 90
local ERROR_NOTICE_DAYS = 30
local LICENSE_NOTIFICATION_INTERVAL = DAY
local LICENSE_NOTIFICATION_LOCK_KEY = "events:license"

local _M = {}
local DEFAULT_KONG_LICENSE_PATH = "/etc/kong/license.json"


local function get_license_string()
  local license_data_env = os.getenv("KONG_LICENSE_DATA")
  if license_data_env then
    ngx.log(ngx.DEBUG, "[license-helpers] loaded license from KONG_LICENSE_DATA")
    return license_data_env
  end

  local license_path
  if pl_path.exists(DEFAULT_KONG_LICENSE_PATH) then
    ngx.log(ngx.DEBUG, "[license-helpers] loaded license from default Kong license path")
    license_path = DEFAULT_KONG_LICENSE_PATH
  else
    license_path = os.getenv("KONG_LICENSE_PATH")
    if not license_path then
      if kong and kong.db and kong.db.licenses then
        -- Load license from database
        local license
        for l in kong.db.licenses:each() do
          -- Select the last updated license
          if not license or license.updated_at < l.updated_at then
            license = l
          end
        end
        if license then
          ngx.log(ngx.DEBUG, "[license-helpers] loaded license from database; using license id: ", license.id)
          return license.payload
        end
      end

      -- License was not loaded from DB so return initial error
      ngx.log(ngx.DEBUG, "[license-helpers] KONG_LICENSE_PATH is not set")
      return nil
    end
  end

  local license_file = io.open(license_path, "r")
  if not license_file then
    ngx.log(ngx.NOTICE, "[license-helpers] could not open license file")
    return nil
  end

  local license_data = license_file:read("*a")
  if not license_data then
    ngx.log(ngx.NOTICE, "[license-helpers] could not read license file contents")
    return nil
  end

  license_file:close()

  ngx.log(ngx.DEBUG, "[license-helpers] loaded license from KONG_LICENSE_PATH")
  return license_data
end


local function license_expiration_time(license)
  local expiration_date = license and
    license.license               and
    license.license.payload       and
    license.license.payload.license_expiration_date

  if not expiration_date or
  not re_find(expiration_date, "^\\d{4}-\\d{2}-\\d{2}$") then
    return
  end

  local date_t = split(expiration_date, "-")
  local ok, res = pcall(os.time, {
    year = tonumber(date_t[1]),
    month = tonumber(date_t[2]),
    day = tonumber(date_t[3])
  })
  if ok then
    return res
  end

  return nil
end


function _M.read_license_info()
  local license_data = get_license_string()
  if not license_data or (license_data == "") then
    ngx.log(ngx.NOTICE, "[license-helpers] could not decode license JSON: No license found")
    return nil
  end

  local license, err = cjson.decode(license_data)
  if err then
    ngx.log(ngx.ERR, "[license-helpers] could not decode license JSON: " .. err)
    return nil
  end

  return license
end

_M.get_type = function(lic)
  local expiration_time = license_expiration_time(lic)

  local l_type

  if not expiration_time then
    l_type = "free"
    -- as of now, there's no config that changes in case we know it is expired from the start'
  elseif expiration_time < ngx.time() then
    l_type = "full_expired"
  else
    l_type = "full"
  end

  return l_type
end


_M.get_featureset = function(l_type)
  local lic
  -- HACK: when called from runner, the license is not read yet, and
  -- even when read there at the call site,
  if not kong or not kong.license then
    lic = _M.read_license_info()
  else
    lic = kong.license
  end

  l_type = l_type or _M.get_type(lic)

  return dist_constants.featureset[l_type]
end


-- Hold a lock for the whole interval (exptime) to prevent multiple
-- worker processes from the  simultaneously.
-- Other workers do not need to wait until this lock is released,
-- and can ignore the event, knowing another worker is handling it.
-- We substract 1ms to the exp time to prevent a race condition
-- with the next timer event.
local function get_lock(key, exptime)
  local ok, err = kong_dict:safe_add(key, true, exptime - 0.001)
  if not ok and err ~= "exists" then
    log(ngx.WARN, "could not get lock from 'kong' shm: ", err)
  end

  return ok
end


local function log_license_state(expiration_time, now)
  local please_contact_str = "Please contact <support@konghq.com> to renew your license."
  local expiration_date = os.date("%Y-%m-%d", expiration_time)

  if expiration_time < now then
    ngx.log(ngx.CRIT, string.format("The Kong Enterprise license expired on %s. "..
                                    please_contact_str, expiration_date))
  elseif expiration_time < now + (ERROR_NOTICE_DAYS * DAY) then
    ngx.log(ngx.ERR, string.format("The Kong Enterprise license will expire on %s. " ..
                                   please_contact_str, expiration_date))
  elseif expiration_time < now + (WARNING_NOTICE_DAYS * DAY) then
    ngx.log(ngx.WARN, string.format("The Kong Enterprise license will expire on %s. " ..
                                    please_contact_str, expiration_date))
  end
end
_M.log_license_state = log_license_state


local function license_notification_handler(premature, expiration_time)
  if premature then
    return
  end

  timer_at(LICENSE_NOTIFICATION_INTERVAL,
           license_notification_handler,
           expiration_time)

  if not get_lock(LICENSE_NOTIFICATION_LOCK_KEY,
                  LICENSE_NOTIFICATION_INTERVAL) then
    return
  end

  log_license_state(expiration_time, ngx.time())
end

local function report_expired_license()
  local expiration_time = license_expiration_time(kong.license)
  if expiration_time then
    timer_at(0,
      license_notification_handler,
      expiration_time)
  end
end
_M.report_expired_license = report_expired_license

-- A before_filter callback that can be applied to a lapis router
function _M.license_can_proceed(self)
  local method = ngx.req.get_method()

  local route = self.route_name
  local allow = kong.licensing.allow_admin_api or {}
  local deny = kong.licensing.deny_admin_api or {}

  if (deny[route] and (deny[route][method] or deny[route]["*"]))
    and not (allow[route] and (allow[route][method] or allow[route]["*"]))
  then
    return kong.response.exit(403, { message = "Enterprise license missing or expired" })
  end

  if not kong.licensing:can("write_admin_api")
    and (method == "POST" or
         method == "PUT" or
         method == "PATCH" or
         method == "DELETE")
    -- Maybe this operation is allowed even with write_admin_api off
    and not (allow[route] and (allow[route][method] or allow[route]["*"]))
  then
    return kong.response.exit(403, { message = "Enterprise license missing or expired" })
  end

  if not license_utils.license_validation_can_proceed()
    and method ~= "GET" then
    -- Force a 400 (Bad Request) and attach the error message
    local msg = "license library cannot be loaded"
    ngx.log(ngx.ERR, msg)
    return kong.response.exit(400, { message = msg })
  end
end

local function validate_kong_license(license)
  return license_utils.validate_kong_license(license)
end

local function is_valid_license(license)
  local result = validate_kong_license(license)
  if result == "ERROR_VALIDATION_PASS" or
     result == "ERROR_GRACE_PERIOD" or
     result == "ERROR_LICENSE_EXPIRED" then
    if result ~= "ERROR_VALIDATION_PASS" then
      local message = "The license being added is expired"
      if result == "ERROR_LICENSE_EXPIRED" then
        message = message .. "; some functionality may not be available"
      end
      ngx.log(ngx.WARN, message)
    end
    return true, cjson.decode(license)
  end

  return false, "Unable to validate license: " .. license_utils.validation_error_to_string(result)
end

_M.validate_kong_license = validate_kong_license
_M.is_valid_license = is_valid_license

return _M