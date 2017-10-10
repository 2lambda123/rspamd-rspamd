--[[
Copyright (c) 2017, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

if confighelp then
  return
end

-- A generic plugin for reputation handling

local E = {}
local N = 'reputation'

local rspamd_logger = require "rspamd_logger"
local rspamd_util = require "rspamd_util"
local lua_util = require "lua_util"
local rspamd_lua_utils = require "lua_util"
local hash = require 'rspamd_cryptobox_hash'
local fun = require "fun"
local redis_params = nil
local default_expiry = 864000 -- 10 day by default

-- IP Selector functions

local function ip_reputation_filter(task, rule)

end

-- Selectors are used to extract reputation tokens
local ip_selector = {
  config = {
    -- keys map between actions and hash elements in bucket,
    -- h is for ham,
    -- s is for spam,
    -- p is for probable spam
    keys_map = {
      ['reject'] = 's',
      ['add header'] = 'p',
      ['rewrite subject'] = 'p',
      ['no action'] = 'h'
    },
    scores = { -- how each component is evaluated
      ['asn'] = 0.4,
      ['country'] = 0.01,
      ['ipnet'] = 0.5,
      ['ip'] = 1.0
    },
    symbol = 'IP_SCORE', -- symbol to be inserted
    asn_suffix = 'a:', -- prefix for ASN hashes
    country_suffix = 'c:', -- prefix for country hashes
    ipnet_suffix = 'n:', -- prefix for ipnet hashes
    lower_bound = 10, -- minimum number of messages to be scored
    min_score = nil,
    max_score = nil,
    score_divisor = 1,
  },
  --dependencies = {"ASN"}, -- ASN is a prefilter now...
  filter = ip_reputation_filter, -- used to get scores
  idempotent = ip_reputation_idempotent -- used to set scores
}

local selectors = {
  ip = ip_selector,
}

local function reputation_dns_init(rule)
  if not rule.backend.config.list then
    rspamd_logger.errx(rspamd_config, "rule %s with DNS backend has no `list` parameter defined",
      rule.symbol)
    return false
  end

  return true
end


local function gen_token_key(token, rule)
  local res = token
  if rule.backend.config.hashed then
    local hash_alg = rule.backend.config.hash_alg or "blake2"
    local encoding = "base32"

    if rule.backend.config.hash_encoding then
      encoding = rule.backend.config.hash_encoding
    end

    local h = hash.create_specific(hash_alg, res)
    if encoding == 'hex' then
      res = h:hex()
    elseif encoding == 'base64' then
      res = h:base64()
    else
      res = h:base32()
    end
  end

  if rule.backend.config.hashlen then
    res = string.sub(res, 1, rule.backend.config.hashlen)
  end

  return res
end

--[[
-- Generic interface for get and set tokens functions:
-- get_token(task, rule, token, continuation), where `continuation` is the following function:
--
-- function(err, token, values) ... end
-- `err`: string value for error (similar to redis or DNS callbacks)
-- `token`: string value of a token
-- `values`: table of key=number, parsed from backend. It is selector's duty
--  to deal with missing, invalid or other values
--
-- set_token(task, rule, token, values, continuation_cb)
-- This function takes values, encodes them using whatever suitable format
-- and calls for continuation:
--
-- function(err, token) ... end
-- `err`: string value for error (similar to redis or DNS callbacks)
-- `token`: string value of a token
--
-- example of tokens: {'s': 0, 'h': 0, 'p': 1}
--]]

local function reputation_dns_get_token(task, rule, token, continuation_cb)
  local r = task:get_resolver()
  local to_resolve = gen_token_key(token)
  local dns_name = to_resolve .. '.' .. rule.backend.config.list

  local function dns_callback(_, to_resolve, results, err)
    if err and (err ~= 'requested record is not found' and err ~= 'no records with this name') then
      rspamd_logger.errx(task, 'error looking up %s: %s', to_resolve, err)
    end
    if not results then
      rspamd_logger.debugm(N, task, 'DNS RESPONSE: label=%1 results=%2 error=%3 list=%4',
        to_resolve, false, err, rule.backend.config.list)
    else
      rspamd_logger.debugm(N, task, 'DNS RESPONSE: label=%1 results=%2 error=%3 list=%4',
        to_resolve, true, err, rule.backend.config.list)
    end

    -- Now split tokens to list of values
    if not err and results then
      local values = {}
      -- Format: key1=num1;key2=num2...keyn=numn
      fun.each(function(e)
          local vals = lua_util.rspamd_str_split(e, "=")
          if vals and #vals == 2 then
            local nv = tonumber[vals[2]]
            if nv then
              values[vals[1]] = nv
            end
          end
        end,
        lua_util.rspamd_str_split(results[1], ";"))
      continuation_cb(nil, to_resolve, values)
    else
      continuation_cb(err, to_resolve, nil)
    end

    task:inc_dns_req()
  end
  r:resolve_a({
    task = task,
    name = dns_name,
    callback = dns_callback,
    forced = true,
  })
end

local function reputation_redis_get_token(task, rule, token, continuation_cb)
  local key = gen_token_key(token)

  local function redis_get_cb(err, data)
    if data then
      if type(data) == 'table' then
        local values = {}
        for i=1,#data,2 do
          local ndata = tonumber(data[i + 1])
          if ndata then
            values[data[i]] = ndata
          end
        end
        continuation_cb(nil, key, values)
      else
        rspamd_logger.errx(task, 'invalid type while getting reputation keys %s: %s',
          key, type(data))
        continuation_cb("invalid type", key, nil)
      end

    elseif err then
      rspamd_logger.errx(task, 'got error while getting reputation keys %s: %s',
        key, err)
      continuation_cb(err, key, nil)
    else
      continuation_cb("unknown error", key, nil)
    end
  end

  local ret = rspamd_redis_make_request(task,
    redis_params, -- connect params
    key, -- hash key
    false, -- is write
    redis_get_cb, --callback
    'HGETALL', -- command
    {key} -- arguments
  )
  if not ret then
    rspamd_logger.errx(task, 'cannot make redis request to check results')
  end
end

local function reputation_redis_set_token(task, rule, token, values, continuation_cb)
  local key = gen_token_key(token)

  local ret,conn,upstream

  local function redis_set_cb(err, data)
    if err then
      rspamd_logger.errx(task, 'got error while setting reputation keys %s: %s',
        key, err)
      continuation_cb(err, key)
    else
      continuation_cb(nil, key)
    end
  end

  -- We start from expiry update
  ret,conn,upstream = rspamd_redis_make_request(task,
    redis_params, -- connect params
    nil, -- hash key
    true, -- is write
    redis_set_cb, --callback
    'EXPIRE', -- command
    {key, tostring(rule.backend.config.expiry)} -- arguments
  )
  -- Update greylisting record expire
  if ret then
    -- Here, we increment all hash keys that are listed in values
    -- E.g. {'s': 1.0} or {'h': -1.0}, floating point allows better flexibility
    fun.each(function(k, v)
      conn:add_cmd('HINCRBYFLOAT', {key, tostring(k), tostring(v)})
    end, values)
    -- Add last modification time (might be not very consistent between updates)
    conn:add_cmd('HSET', {key, 'last', tostring(rspamd_util:get_calendar_ticks())})
  else
    rspamd_logger.errx(task, 'got error while connecting to redis')
  end
end

--[[ Backends are responsible for getting reputation tokens
  -- Common config options:
  -- `hashed`: if `true` then apply hash function to the key
  -- `hash_alg`: use specific hash type (`blake2` by default)
  -- `hash_len`: strip hash to this amount of bytes (no strip by default)
  -- `hash_encoding`: use specific hash encoding (base32 by default)
--]]
local backends = {
  redis = {
    config = {
      expiry = default_expiry
    },
    get_token = reputation_redis_get_token,
    set_token = reputation_redis_set_token,
  },
  dns = {
    config = {
      -- list = rep.example.com
    },
    get_token = reputation_dns_get_token,
    -- No set token for DNS
    init = reputation_dns_init,
  }
}

local function reputation_filter_cb(task, rule)
  rule.selector.filter(task, rule, rule.backend)
end

local function reputation_postfilter_cb(task, rule)
  rule.selector.postfilter(task, rule, rule.backend)
end

local function reputation_idempotent_cb(task, rule)
  rule.selector.idempotent(task, rule, rule.backend)
end

local function deepcopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deepcopy(orig_key)] = deepcopy(orig_value)
    end
    setmetatable(copy, deepcopy(getmetatable(orig)))
  else -- number, string, boolean, etc
    copy = orig
  end
  return copy
end
local function override_defaults(def, override)
  for k,v in pairs(override) do
    if def[k] then
      if type(v) == 'table' then
        override_defaults(def[k], v)
      else
        def[k] = v
      end
    else
      def[k] = v
    end
  end
end

local rules = {}

local function callback_gen(cb, rule)
  return function(task)
    cb(task, rule)
  end
end

local function parse_rule(name, tbl)
  local selector = selectors[tbl.selector['type']]

  if not selector then
    rspamd_logger.errx(rspamd_config, "unknown selector defined for rule %s: %s", name,
      tbl.selector.type)
    return
  end

  local backend = tbl.backend
  if not backend or not backend.type then
    rspamd_logger.errx(rspamd_config, "no backend defined for rule %s", name)
    return
  end

  backend = backends[backend.type]
  if not backend then
    rspamd_logger.errx(rspamd_config, "unknown backend defined for rule %s: %s", name,
      tbl.backend.type)
    return
  end
  -- Allow config override
  local rule = {
    selector = deepcopy(selector),
    backend = deepcopy(backend)
  }

  -- Override default config params
  override_defaults(rule.backend.config, tbl.backend)
  override_defaults(rule.selector.config, tbl.selector)

  local symbol = name
  if tbl.symbol then
    symbol = name
  end

  rule.symbol = symbol

  -- Perform additional initialization if needed
  if rule.selector.init then
    if not rule.selector.init(rule) then
      return
    end
  end
  if rule.backend.init then
    if not rule.backend.init(rule) then
      return
    end
  end

  -- We now generate symbol for checking
  local id = rspamd_config:register_symbol{
    name = symbol,
    type = 'normal',
    callback = callback_gen(reputation_filter_cb, rule),
  }

  if rule.selector.dependencies then
    fun.each(function(d)
      rspamd_config:register_dependency(id, d)
    end, rule.selector.dependencies)
  end

  if rule.selector.postfilter then
    -- Also register a postfilter
    rspamd_config:register_symbol{
      name = symbol .. '_POST',
      type = 'postfilter,nostat',
      callback = callback_gen(reputation_postfilter_cb, rule),
    }
  end

  if rule.selector.idempotent then
    -- Has also idempotent component (e.g. saving data to the backend)
    rspamd_config:register_symbol{
      name = symbol .. '_IDEMPOTENT',
      type = 'idempotent',
      callback = callback_gen(reputation_idempotent_cb, rule),
    }
  end

  rules.symbol = rule
end

redis_params = rspamd_parse_redis_server('reputation')
local opts = rspamd_config:get_all_opt("reputation")

-- Initialization part
if not (opts and type(opts) == 'table') then
  rspamd_logger.infox(rspamd_config, 'Module is unconfigured')
  return
end

if opts['rules'] then
  for k,v in opts['rules'] do
    if not v.selector or not v.selector.type then
      rspamd_logger.errx(rspamd_config, "no selector defined for rule %s", k)
    else
      parse_rule(k, v)
    end
  end
end
