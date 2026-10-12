local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local providers = require("meatcode.providers")
local runner = require("meatcode.runner")
local tabs = require("meatcode.ui.tab")
local util = require("meatcode.util")

--- Fallback-chain configurator: reorder the provider chain (statement, tests,
--- starter code and judge all come from the first provider that can serve a
--- problem) and choose when that judge's test run (the cloud oracle) replaces
--- local oracles. Saving persists both as the new default for every problem
--- opened afterwards.
local M = {}

--- What each cloud-oracle setting means, in `runner.CLOUD_MODES` order.
local CLOUD_MODE_LABEL = {
  complex = "complex problems without an openleetcode checker",
  always = "every problem",
  never = "never (only when nothing local is available)",
}

local state = { buf = nil, win = nil, rows = {} }

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

function M.close()
  if is_open() then pcall(vim.api.nvim_win_close, state.win, true) end
  state.win, state.buf, state.rows = nil, nil, {}
end

local function move(from, delta)
  local chain = providers.order()
  local to = from + delta
  if from < 1 or from > #chain or to < 1 or to > #chain then return end
  chain[from], chain[to] = chain[to], chain[from]
  providers.set_order(chain)
end

--- Advance the cloud-oracle setting to the next mode.
local function cycle_cloud_mode()
  local modes, current = runner.CLOUD_MODES, runner.cloud_mode()
  for i, mode in ipairs(modes) do
    if mode == current then
      runner.set_cloud_mode(modes[i % #modes + 1])
      break
    end
  end
end

local function render()
  if not is_open() then return end
  local active = require("meatcode.ui.problem").active()
  local lines, spans, rows = { "", "  provider fallback chain", "" }, {}, {}
  table.insert(spans, { 1, 2, 2 + #"provider fallback chain", "MeatCodeHeader" })

  table.insert(lines, "  statement, tests, starter code and judge")
  table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })
  for i, name in ipairs(providers.order()) do
    local backend = providers.get(name)
    local in_use = active and active.provider == name
    local line = string.format("  %s %d. %s", in_use and "▸" or " ", i, backend.label)
    table.insert(lines, line)
    table.insert(spans, { #lines - 1, #line - #backend.label, #line, in_use and "MeatCodePass" or "MeatCodeKey" })
    rows[#lines] = { index = i }
  end
  table.insert(lines, "")

  table.insert(lines, "  cloud oracle")
  table.insert(spans, { #lines - 1, 2, 2 + #"cloud oracle", "MeatCodeMuted" })
  table.insert(lines, "  the problem's judge's test run, cached answers first")
  table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })
  local mode_label = CLOUD_MODE_LABEL[runner.cloud_mode()]
  local mode_line = "    replaces local oracles for: " .. mode_label
  table.insert(lines, mode_line)
  table.insert(spans, { #lines - 1, #mode_line - #mode_label, #mode_line, "MeatCodeKey" })
  rows[#lines] = { setting = "cloud" }
  table.insert(lines, "")

  if active then
    table.insert(lines, string.format("  ▸ in use for %s", active.name))
    table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })
  end
  table.insert(lines, "  <C-k>/<C-j> move row · <CR> change setting · <Tab> next section · q closes")
  table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  hl.apply(state.buf, spans)
  state.rows = rows
end

function M.refresh()
  render()
end

local function current()
  if not is_open() then return nil end
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end
  local function nudge(delta)
    local row = current()
    if not row or not row.index then return util.notify("put the cursor on a provider row") end
    move(row.index, delta)
    render()
    local target = nil
    for linenr, entry in pairs(state.rows) do
      if entry.index == row.index + delta then target = linenr end
    end
    if target then pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 }) end
  end
  map("<C-k>", function() nudge(-1) end, "Move provider earlier")
  map("<C-j>", function() nudge(1) end, "Move provider later")
  map("K", function() nudge(-1) end, "Move provider earlier")
  map("J", function() nudge(1) end, "Move provider later")
  map("<Tab>", function()
    local starts, seen = {}, {}
    for linenr, entry in pairs(state.rows) do
      local section = entry.setting or "providers"
      if not seen[section] or linenr < seen[section] then seen[section] = linenr end
    end
    for _, linenr in pairs(seen) do table.insert(starts, linenr) end
    table.sort(starts)
    local cursor = vim.api.nvim_win_get_cursor(state.win)[1]
    local target = starts[1]
    for _, linenr in ipairs(starts) do
      if linenr > cursor then
        target = linenr
        break
      end
    end
    if target then pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 }) end
  end, "Jump to next section")
  map("<CR>", function()
    local row = current()
    if not row or row.setting ~= "cloud" then return util.notify("put the cursor on a setting row") end
    cycle_cloud_mode()
    render()
  end, "Change setting")
  map("q", M.close, "Close chain")
  map("<Esc>", M.close, "Close chain")
end

function M.open()
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "meatcode-chains"
  tabs.name_buffer(state.buf, "provider chain")

  local width = math.min(vim.o.columns - 8, 84)
  local height = math.min(vim.o.lines - 8, 24)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = config.options.ui.border,
    title = " Provider chain ",
    title_pos = "center",
  })
  vim.wo[state.win][0].cursorline = true

  keymaps()
  render()
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function() state.win, state.buf = nil, nil end,
  })
end

return M
