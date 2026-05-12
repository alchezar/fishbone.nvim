-- Horizontal "fishbone" position bar. Layout:
--   <file path> [+]   <bar fills the rest of the row>   <E> <W>  L:C  P%
-- The bar maps every file line to a column on the bottom row. Each cell is
-- a composition of a top half (overview) and a bottom half (signals):
--
-- Top-half (z-ordered, highest wins):
--   cursor   white   ▀
--   search   pink    ▀ - line currently matches the active /search pattern
--   mark     yellow  ▀ - vim a-z mark or marks.nvim bookmark
--   viewport silver  ▀
--
-- Bottom-half (z-ordered, highest wins):
--   error    red     ▄
--   warn     orange  ▄
--   git chg  blue    ▄
--   git add  green   ▄
--   info     cyan    ▄
--   hint     purple  ▄
--
-- Cells: `▀` (fg=top, bg=bot) when both halves carry info, `▄` (fg=bot) when
-- only bottom, `▀` (fg=top) when only top, `█` for cursor alone, `·` empty.

local M = {}

local config = {
  colors = {
    cursor     = '#FFFFFF',
    search     = '#FF77AA',
    mark       = '#FFD866',
    viewport   = '#888888',
    error      = '#FC6161',
    warn       = '#FFA348',
    info       = '#67D4F0',
    hint       = '#C792EA',
    git_add    = '#7FCC7F',
    git_change = '#7FAFFF',
    base       = '#444444',
    file       = '#AAAAAA',
    dim        = '#444444',
    info_txt   = '#BBBBBB',
  },
}

local TOP_PRIORITY = { 'cursor', 'search', 'mark', 'viewport' }
local BOT_NAMES    = { 'error', 'warn', 'git_change', 'git_add', 'info', 'hint' }
-- Diagnostic severity (1..4) -> bottom-layer name
local DIAG_BOT     = { 'error', 'warn', 'info', 'hint' }

-- Geometry snapshot captured on each render(), used by on_click() to map a
-- mouse click on the bar back to a buffer line. Refreshed every redraw so
-- it always matches what the user actually sees.
local last = { left_w = 0, bar_width = 0, total_lines = 1 }

-- True between a press that landed on the bar and the matching release.
-- While set, drag events steer the cursor regardless of mouse Y, and X is
-- clamped to bar bounds - so the user can wander above or below the bar
-- without losing the drag.
local dragging = false

local function top_colors() return {
  cursor   = config.colors.cursor,
  search   = config.colors.search,
  mark     = config.colors.mark,
  viewport = config.colors.viewport,
} end
local function bot_colors() return {
  error      = config.colors.error,
  warn       = config.colors.warn,
  git_change = config.colors.git_change,
  git_add    = config.colors.git_add,
  info       = config.colors.info,
  hint       = config.colors.hint,
} end

local function setup_hl()
  local tc, bc = top_colors(), bot_colors()
  -- Top-only cells: `▀` fg=top_color
  for name, color in pairs(tc) do
    vim.api.nvim_set_hl(0, 'FbnT_' .. name,
      { fg = color, bold = (name == 'cursor') })
  end
  -- Bottom-only cells: `▄` fg=bottom_color
  for name, color in pairs(bc) do
    vim.api.nvim_set_hl(0, 'FbnB_' .. name, { fg = color })
  end
  -- Both halves: `▀` fg=top, bg=bottom
  for tname, tcol in pairs(tc) do
    for bname, bcol in pairs(bc) do
      vim.api.nvim_set_hl(0, 'FbnT_' .. tname .. '_B_' .. bname,
        { fg = tcol, bg = bcol, bold = (tname == 'cursor') })
    end
  end
  vim.api.nvim_set_hl(0, 'FbnBase',        { fg = config.colors.base })
  vim.api.nvim_set_hl(0, 'FbnCursorBlock', { fg = config.colors.cursor, bold = true })
  vim.api.nvim_set_hl(0, 'FbnFile',        { fg = config.colors.file })
  vim.api.nvim_set_hl(0, 'FbnDim',         { fg = config.colors.dim })
  vim.api.nvim_set_hl(0, 'FbnInfoTxt',     { fg = config.colors.info_txt })
  vim.api.nvim_set_hl(0, 'FbnErrorTxt',    { fg = config.colors.error })
  vim.api.nvim_set_hl(0, 'FbnWarnTxt',     { fg = config.colors.warn })
end

local function diag_counts(diags)
  local c = { 0, 0, 0, 0 }
  for _, d in ipairs(diags) do c[d.severity] = c[d.severity] + 1 end
  return c
end

-- Set of buffer lines that hold a vim a-z mark or a marks.nvim bookmark.
local function mark_lines(bufnr)
  local out = {}
  for _, m in ipairs(vim.fn.getmarklist(bufnr)) do
    local name = m.mark or ''
    -- m.mark is like "'a"; we only want letter marks, skip jump marks.
    if name:match("^'[a-zA-Z]$") then
      local lnum = m.pos and m.pos[2]
      if lnum and lnum > 0 then out[lnum] = true end
    end
  end
  local ok, marks_api = pcall(require, 'marks')
  if ok and marks_api.bookmark_state and marks_api.bookmark_state.groups then
    for _, group in pairs(marks_api.bookmark_state.groups) do
      local buf_marks = group.marks and group.marks[bufnr] or nil
      if buf_marks then
        for lnum, _ in pairs(buf_marks) do out[lnum] = true end
      end
    end
  end
  return out
end

-- Search-match line set, cached on (bufnr, tick, pattern) so we don't rescan
-- the buffer on every statusline redraw.
local search_cache = { bufnr = -1, tick = -1, pat = '', lines = {} }
local function search_lines(bufnr)
  if vim.v.hlsearch == 0 then return {} end
  local pat = vim.fn.getreg('/')
  if pat == '' then return {} end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if search_cache.bufnr == bufnr
     and search_cache.tick == tick
     and search_cache.pat == pat then
    return search_cache.lines
  end
  local hits = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if vim.fn.match(line, pat) >= 0 then hits[i] = true end
  end
  search_cache = { bufnr = bufnr, tick = tick, pat = pat, lines = hits }
  return hits
end

-- lnum -> bottom-name for git-changed lines.
local function git_marks(bufnr)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then return {} end
  local hunks = gitsigns.get_hunks and gitsigns.get_hunks(bufnr) or {}
  local marks = {}
  for _, h in ipairs(hunks) do
    if h.added and h.added.count and h.added.count > 0 then
      local name = (h.type == 'change') and 'git_change' or 'git_add'
      for lnum = h.added.start, h.added.start + h.added.count - 1 do
        marks[lnum] = name
      end
    end
  end
  return marks
end

local function colored_count(n, sev_hl, width)
  local hl = n > 0 and sev_hl or 'FbnDim'
  return string.format('%%#%s#%' .. width .. 'd', hl, n)
end

function M.render()
  local bufnr = vim.api.nvim_win_get_buf(0)
  local total_lines = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local cursor_lnum = vim.fn.line('.')
  local cursor_col  = vim.fn.col('.')
  local pct = math.floor((cursor_lnum / total_lines) * 100 + 0.5)

  local view_top = vim.fn.line('w0')
  local view_bot = vim.fn.line('w$')

  local diags = vim.diagnostic.get(bufnr)
  local cnt = diag_counts(diags)
  local git = git_marks(bufnr)
  local marks_by_line  = mark_lines(bufnr)
  local search_by_line = search_lines(bufnr)

  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
  if file == '' then file = '[No Name]' end
  local modified = vim.bo.modified and ' [+]' or ''
  local left_plain = ' ' .. file .. modified .. '  '
  local left_segment = string.format('%%#FbnFile# %s%s  ', file, modified)

  local cnt_w  = 3
  local line_w = math.max(3, #tostring(total_lines))
  local col_w  = 3
  local pct_w  = 3
  local right_plain = string.format(
    '  %' .. cnt_w .. 'd %' .. cnt_w .. 'd  %' .. line_w .. 'd:%' .. col_w
    .. 'd  %' .. pct_w .. 'd%% ',
    cnt[1], cnt[2], cursor_lnum, cursor_col, pct)
  local right_segment = string.format(
    '  %s %s  %%#FbnInfoTxt#%' .. line_w .. 'd:%-' .. col_w
    .. 'd  %' .. pct_w .. 'd%%%% ',
    colored_count(cnt[1], 'FbnErrorTxt', cnt_w),
    colored_count(cnt[2], 'FbnWarnTxt',  cnt_w),
    cursor_lnum, cursor_col, pct)

  local bar_width = vim.o.columns - #left_plain - #right_plain
  if bar_width < 6 then
    last.bar_width = 0
    return left_segment .. '%=' .. right_segment
  end
  last.left_w     = #left_plain
  last.bar_width  = bar_width
  last.total_lines = total_lines

  local function lnum_to_col(lnum)
    local col = math.floor(((lnum - 1) / math.max(1, total_lines - 1))
                           * (bar_width - 1)) + 1
    if col < 1 then return 1 end
    if col > bar_width then return bar_width end
    return col
  end

  local view_start = lnum_to_col(view_top)
  local view_end   = lnum_to_col(view_bot)
  local cursor_x   = lnum_to_col(cursor_lnum)

  -- Per-column resolved bottom layer (lower prio number wins).
  local bot = {}
  local function put_bot(col, name, prio)
    local cur = bot[col]
    if not cur or cur.prio > prio then
      bot[col] = { name = name, prio = prio }
    end
  end
  for _, d in ipairs(diags) do
    local name = DIAG_BOT[d.severity]
    if name then
      -- error=1, warn=2, info=5, hint=6 (git change/add slip between)
      local prio = ({ 1, 2, 5, 6 })[d.severity]
      put_bot(lnum_to_col(d.lnum + 1), name, prio)
    end
  end
  for lnum, name in pairs(git) do
    local prio = (name == 'git_change') and 3 or 4
    put_bot(lnum_to_col(lnum), name, prio)
  end

  local search_col = {}
  for lnum in pairs(search_by_line) do search_col[lnum_to_col(lnum)] = true end
  local mark_col = {}
  for lnum in pairs(marks_by_line) do mark_col[lnum_to_col(lnum)] = true end

  local parts = {}
  for col = 1, bar_width do
    local top
    if col == cursor_x then
      top = 'cursor'
    elseif search_col[col] then
      top = 'search'
    elseif mark_col[col] then
      top = 'mark'
    elseif col >= view_start and col <= view_end then
      top = 'viewport'
    end

    local b = bot[col] and bot[col].name or nil

    local hl, ch
    if top == 'cursor' and not b then
      hl, ch = 'FbnCursorBlock', '█'
    elseif top and b then
      hl, ch = 'FbnT_' .. top .. '_B_' .. b, '▀'
    elseif top then
      hl, ch = 'FbnT_' .. top, '▀'
    elseif b then
      hl, ch = 'FbnB_' .. b, '▄'
    else
      hl, ch = 'FbnBase', '·'
    end
    parts[#parts+1] = '%#' .. hl .. '#' .. ch
  end

  local bar_segment = '%@FishboneClick@' .. table.concat(parts) .. '%X'
  return left_segment .. bar_segment .. right_segment
end

-- Map a mouse position to a buffer line and jump there. `add_jump` controls
-- whether to push a jumplist entry: true for an initial click (so <C-o>
-- works), false for drag ticks (otherwise every drag tick spams the list).
-- `clamp` clips the horizontal position to bar bounds; used during drag so
-- mouse Y can roam freely and X past the edges sticks at the extreme.
local function jump_from_mouse(mp, add_jump, clamp)
  if last.bar_width <= 0 then return false end
  local col_in_bar = mp.screencol - last.left_w
  if clamp then
    if col_in_bar < 1 then col_in_bar = 1 end
    if col_in_bar > last.bar_width then col_in_bar = last.bar_width end
  elseif col_in_bar < 1 or col_in_bar > last.bar_width then
    return false
  end
  local total = math.max(1, last.total_lines)
  local denom = math.max(1, last.bar_width - 1)
  local lnum = math.floor((col_in_bar - 1) / denom * (total - 1) + 0.5) + 1
  if lnum < 1 then lnum = 1 end
  if lnum > total then lnum = total end
  if add_jump then vim.cmd("normal! m'") end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
end

-- Called via the `%@FishboneClick@` region in the rendered statusline.
function M.on_click(_, _, button, _)
  if button ~= 'l' then return end
  if jump_from_mouse(vim.fn.getmousepos(), true, false) then
    dragging = true
  end
end

-- The `%@FuncName@` format in 'statusline' expects a plain vimscript
-- function name; wrap the Lua callback so it can be referenced by name.
-- Works in terminal Neovim; Neovide ignores statusline click handlers, so
-- the keymap fallback in setup() takes over there.
vim.cmd([[
  function! FishboneClick(minwid, clicks, button, mods) abort
    call v:lua.require('fishbone').on_click(
      \ a:minwid, a:clicks, a:button, a:mods)
  endfunction
]])

function M.setup(opts)
  opts = opts or {}
  if opts.colors then
    config.colors = vim.tbl_extend('force', config.colors, opts.colors)
  end
  setup_hl()

  vim.opt.statusline = '%!v:lua.require("fishbone").render()'
  vim.opt.laststatus = 3

  -- Neovide doesn't route clicks to %@...@ regions, so catch <LeftMouse>
  -- ourselves on the global-statusline row (Neovide reports a non-zero
  -- winid for the bar area, so detect by screenrow).
  if vim.g.neovide then
    vim.keymap.set({ 'n', 'i', 'v' }, '<LeftMouse>', function()
      local mp = vim.fn.getmousepos()
      if mp.screenrow == vim.o.lines - vim.o.cmdheight
         and last.bar_width > 0 then
        local col_in_bar = mp.screencol - last.left_w
        if col_in_bar >= 1 and col_in_bar <= last.bar_width then
          dragging = true
          vim.schedule(function() jump_from_mouse(mp, true, false) end)
          return ''
        end
      end
      dragging = false
      return '<LeftMouse>'
    end, { expr = true })
  end

  -- Drag and release: work in both terminal and Neovide. %@..@ regions
  -- don't receive these events, so a keymap is the only path. Once a drag
  -- starts on the bar, every drag tick repositions the cursor regardless
  -- of mouse Y; X is clamped to bar bounds.
  vim.keymap.set({ 'n', 'i', 'v' }, '<LeftDrag>', function()
    if dragging then
      local mp = vim.fn.getmousepos()
      vim.schedule(function() jump_from_mouse(mp, false, true) end)
      return ''
    end
    return '<LeftDrag>'
  end, { expr = true })

  vim.keymap.set({ 'n', 'i', 'v' }, '<LeftRelease>', function()
    if dragging then
      dragging = false
      return ''
    end
    return '<LeftRelease>'
  end, { expr = true })

  local group = vim.api.nvim_create_augroup('Fishbone', { clear = true })
  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'WinScrolled', 'BufEnter',
      'DiagnosticChanged', 'VimResized', 'TextChanged', 'TextChangedI' },
    { group = group, callback = function() vim.cmd('redrawstatus') end }
  )
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'GitSignsUpdate',
    callback = function() vim.cmd('redrawstatus') end,
  })
  -- Search pattern changes redraw via CmdlineLeave on /, ?, and :nohlsearch.
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = group, callback = function() vim.cmd('redrawstatus') end,
  })
  vim.api.nvim_create_autocmd('ColorScheme',
    { group = group, callback = setup_hl })
end

return M
