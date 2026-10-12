local M = {}

--- Every known provider, in canonical order. Completion keys and solution
--- filenames derive from this, so it never follows user configuration.
M.NAMES = { "leetcode", "neetcode", "lintcode" }

--- The one fallback chain: the first provider in it that can serve a problem
--- supplies its statement, tests and starter code, and judges its runs and
--- submissions. Persisted in the cache dir and edited through the <leader>nc
--- configurator, never via setup().

local loaded = {}
local chain = nil

function M.known(name)
  return vim.tbl_contains(M.NAMES, name)
end

function M.get(name)
  if not M.known(name) then return nil end
  if not loaded[name] then loaded[name] = require("meatcode.providers." .. name) end
  return loaded[name]
end

function M.all()
  local out = {}
  for _, name in ipairs(M.NAMES) do table.insert(out, M.get(name)) end
  return out
end

local function chain_path()
  return require("meatcode.config").options.cache_dir .. "/provider-order.json"
end

--- Unknown names are dropped; an empty result falls back to every provider.
local function sanitize(names)
  local out, seen = {}, {}
  for _, name in ipairs(type(names) == "table" and names or {}) do
    if M.known(name) and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  if #out == 0 then return { unpack(M.NAMES) } end
  return out
end

--- The provider fallback chain.
function M.order()
  if not chain then chain = sanitize(require("meatcode.util").read_json(chain_path())) end
  return { unpack(chain) }
end

--- Replace the fallback chain and persist it as the new default.
---@return string[] the sanitized chain actually stored
function M.set_order(names)
  chain = sanitize(names)
  require("meatcode.util").write_json(chain_path(), chain)
  vim.api.nvim_exec_autocmds("User", { pattern = "MeatCodeStateChanged", data = { chain = true } })
  return M.order()
end

function M.id(problem, name)
  local record = type(problem) == "table" and type(problem.providers) == "table"
    and problem.providers[name] or nil
  return type(record) == "table" and record.id or nil
end

function M.available(problem, name)
  return M.id(problem, name) ~= nil
end

--- Providers from the chain that could serve `problem`. LintCode stays a
--- candidate whenever LeetCode is present, since its id resolves on demand.
function M.candidates(problem)
  local out = {}
  for _, name in ipairs(M.order()) do
    if M.available(problem, name)
      or (name == "lintcode" and M.available(problem, "leetcode")) then
      table.insert(out, name)
    end
  end
  return out
end

function M.problem_key(problem)
  if type(problem) == "table" and type(problem.key) == "string" then return problem.key end
  for _, name in ipairs(M.NAMES) do
    local id = M.id(problem, name)
    if id then return name .. ":" .. tostring(id) end
  end
end

--- Stable on-disk identity: the first known provider id, so solution files
--- keep their names whatever the configured fallback order is.
function M.filename(problem)
  for _, name in ipairs(M.NAMES) do
    local id = M.id(problem, name)
    if id then return tostring(id) end
  end
end

--- Whether a paid-only problem on `name` is worth attempting to open for
--- this user, and what a UI should credit it to ("needs Premium" vs "needs
--- VIP"). This is not consulted by the availability probe (`catalog/
--- availability.lua`), which already judges each fetch's own
--- already-authenticated response instead of guessing from a subscription
--- tier: LeetCode needs Premium (`userStatus.isPremium`) and LintCode needs
--- VIP or SVIP (`accounts/profile`'s `is_vip`/`is_svip`), both captured at
--- login and exposed via each backend's `auth.user()`. Being merely logged
--- in unlocks neither -- verified by probing both with a logged-in,
--- non-subscribed session and getting the same wall back. NeetCode exposes
--- no subscription signal at all: an authenticated request against a
--- Pro-locked problem still comes back with no
--- `starterCode`/`availableLanguages`, so this plugin has no way to unlock
--- NeetCode Pro content.
function M.paid_unlocked(name)
  local backend = M.get(name)
  if not backend or not backend.auth.is_logged_in() then return false end
  if name == "leetcode" then
    local user = backend.auth.user()
    return type(user) == "table" and user.isPremium == true
  end
  if name == "lintcode" then
    local user = backend.auth.user()
    local profile = type(user) == "table" and user.profile
    return type(profile) == "table" and (profile.is_vip == true or profile.is_svip == true)
  end
  return false
end

function M.locked(problem, name)
  local record = type(problem) == "table" and type(problem.providers) == "table"
    and problem.providers[name] or nil
  return type(record) == "table" and record.paid == true and not M.paid_unlocked(name)
end

--- Whether `meta` from `name` carries an accessible `lang` starter for this user.
function M.can_open(name, meta, lang)
  if type(meta) ~= "table" then return false end
  if meta.paid_only and not M.paid_unlocked(name) then return false end
  if type(meta.availableLanguages) == "table"
    and not vim.tbl_contains(meta.availableLanguages, lang) then
    return false
  end
  local starter = type(meta.starterCode) == "table" and meta.starterCode[lang] or nil
  return type(starter) == "string" and starter ~= ""
end

function M.ensure_id(problem, name, cb)
  local id = M.id(problem, name)
  if id then return cb(nil, id) end
  local provider = M.get(name)
  if not provider or not provider.resolve then return cb(nil, nil) end
  provider.resolve(problem, function(err, resolved)
    if err or not resolved then return cb(err, resolved) end
    problem.providers = problem.providers or {}
    problem.providers[name] = problem.providers[name] or {}
    problem.providers[name].id = resolved
    cb(nil, resolved)
  end)
end

function M.links(problem)
  local links = {}
  for _, provider in ipairs(M.all()) do
    for _, link in ipairs(provider.links(problem) or {}) do table.insert(links, link) end
  end
  return links
end

return M
