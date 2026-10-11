local M = {}

--- Every known provider, in canonical order. Completion keys and solution
--- filenames derive from this, so it never follows user configuration.
M.NAMES = { "leetcode", "neetcode", "lintcode" }

--- Fallback-chain slots. `content` chooses statement/tests/starter, `submit`
--- chooses the judge. Chains persist in the cache dir and are edited through
--- the <leader>nc configurator, never via setup().
M.SLOTS = { "content", "submit" }

local loaded = {}
local chains = nil

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

local function chains_path()
  return require("meatcode.config").options.cache_dir .. "/provider-chains.json"
end

local function sanitize(chain)
  local out, seen = {}, {}
  for _, name in ipairs(type(chain) == "table" and chain or {}) do
    if M.known(name) and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  if #out == 0 then return { unpack(M.NAMES) } end
  return out
end

local function load_chains()
  if chains then return chains end
  local saved = require("meatcode.util").read_json(chains_path())
  chains = {
    content = sanitize(saved and saved.content),
    submit = sanitize(saved and saved.submit),
  }
  return chains
end

--- The fallback chain for `slot` ("content" or "submit"). Unknown names are
--- dropped; an empty result falls back to every provider.
function M.order(slot)
  return { unpack(load_chains()[slot == "submit" and "submit" or "content"]) }
end

--- Replace the fallback chain for `slot` and persist it as the new default.
---@return string[] the sanitized chain actually stored
function M.set_order(slot, chain)
  slot = slot == "submit" and "submit" or "content"
  load_chains()[slot] = sanitize(chain)
  require("meatcode.util").write_json(chains_path(), chains)
  vim.api.nvim_exec_autocmds("User", { pattern = "MeatCodeStateChanged", data = { chain = slot } })
  return M.order(slot)
end

function M.id(problem, name)
  local record = type(problem) == "table" and type(problem.providers) == "table"
    and problem.providers[name] or nil
  return type(record) == "table" and record.id or nil
end

function M.available(problem, name)
  return M.id(problem, name) ~= nil
end

--- Providers from `slot`'s chain that could serve `problem`. LintCode stays a
--- candidate whenever LeetCode is present, since its id resolves on demand.
function M.candidates(problem, slot)
  local out = {}
  for _, name in ipairs(M.order(slot)) do
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

local function is_provider_adapt_error(err)
  if type(err) ~= "string" then return false end
  return err:find("^the submit judge has no ") ~= nil
    or err:find("^cross%-provider submission adaptation is not implemented") ~= nil
    or err:find("^could not read the judge's ") ~= nil
    or err:find("^could not read the content provider's ") ~= nil
    or err:find("; use the judge's starter$") ~= nil
end

--- Cross-provider function submissions use the judge's signature in every language.
--- Adapt only the payload; unsupported adapters fail before any code is uploaded.
--- When `submit_provider` is a fallback list, providers that cannot open or
--- adapt `problem` in `lang` (paid-locked, missing, or incompatible starter)
--- fall through to the next candidate in the chain.
function M.submit(problem, meta, code, lang, content_provider, submit_provider, cb, on_select)
  local candidates = type(submit_provider) == "table" and submit_provider or { submit_provider }
  local index = 0
  local first_err, first_name

  local function remember(name, err)
    if not first_err then first_err, first_name = err, name end
  end

  local function try_next()
    index = index + 1
    local name = candidates[index]
    if not name then
      return cb(first_err or "no submit provider succeeded", nil, first_name)
    end
    local backend = M.get(name)
    if not backend then return try_next() end
    local has_more = index < #candidates

    if name == content_provider then
      if meta and meta.paid_only and not M.paid_unlocked(name) then
        remember(name, (problem.name or "this problem") .. " is paid-only on " .. backend.label)
        if has_more then return try_next() end
        return cb(first_err, nil, first_name)
      end
      if on_select then on_select(name) end
      return backend.submit(problem, meta, code, lang, function(err, data)
        cb(err, data, name)
      end)
    end

    if on_select then on_select(name) end
    M.ensure_id(problem, name, function(err, id)
      if err or not id then
        remember(name, err or ("problem is unavailable on " .. backend.label))
        if has_more then return try_next() end
        return cb(first_err, nil, first_name)
      end
      backend.fetch(problem, lang, function(fetch_err, judge)
        if type(judge) == "table" and judge.paid_only ~= nil
          and type(problem) == "table" and type(problem.providers) == "table"
          and type(problem.providers[name]) == "table" then
          problem.providers[name].paid = judge.paid_only == true
        end
        if fetch_err or not judge then
          remember(name, fetch_err or ("could not load " .. backend.label .. "'s " .. require("meatcode.lang").name(lang) .. " starter"))
          if has_more then return try_next() end
          return cb(first_err, nil, first_name)
        end
        if judge.paid_only and not M.paid_unlocked(name) then
          remember(name, (problem.name or "this problem") .. " is paid-only on " .. backend.label)
          if has_more then return try_next() end
          return cb(first_err, nil, first_name)
        end
        if type(judge.availableLanguages) == "table"
          and not vim.tbl_contains(judge.availableLanguages, lang) then
          remember(name, require("meatcode.lang").name(lang) .. " is unavailable on " .. backend.label)
          if has_more then return try_next() end
          return cb(first_err, nil, first_name)
        end
        if meta.test_case_type == "class" then
          local starter = type(judge.starterCode) == "table" and judge.starterCode[lang] or nil
          if type(starter) ~= "string" or starter == "" then
            remember(name, "the submit judge has no " .. require("meatcode.lang").name(lang) .. " starter signature")
            if has_more then return try_next() end
            return cb(first_err, nil, first_name)
          end
          return backend.submit(problem, judge, code, lang, function(sub_err, data)
            cb(sub_err, data, name)
          end)
        end
        if judge.test_case_type == "class" then
          remember(name, "the submit judge requires a design-class API; use its starter")
          if has_more then return try_next() end
          return cb(first_err, nil, first_name)
        end
        local payload, adapt_err = require("meatcode.submission").adapt(
          code, lang, (meta.starterCode or {})[lang], (judge.starterCode or {})[lang])
        if not payload then
          remember(name, adapt_err)
          if has_more and is_provider_adapt_error(adapt_err) then return try_next() end
          return cb(adapt_err, nil, name)
        end
        backend.submit(problem, judge, payload, lang, function(sub_err, data)
          cb(sub_err, data, name)
        end)
      end)
    end)
  end

  try_next()
end

function M.links(problem)
  local links = {}
  for _, provider in ipairs(M.all()) do
    for _, link in ipairs(provider.links(problem) or {}) do table.insert(links, link) end
  end
  return links
end

return M
