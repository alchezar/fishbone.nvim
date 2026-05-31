-- Horizontal "fishbone" position bar. Layout:
--   <file path> [+]   <bar fills the rest of the row>   <E> <W>  L:C  P%
-- The bar maps every file line to a column on the bottom row. Each cell is
-- a composition of a top half (overview) and a bottom half (signals):
--
-- Top-half (z-ordered, highest wins):
--   cursor    white   ▀
--   search    pink    ▀ - line currently matches the active /search pattern
--   mark      yellow  ▀ - vim a-z mark or marks.nvim bookmark
--   selection blue    ▀ - lines covered by the active visual selection
--   viewport  silver  ▀
-- Where selection and viewport overlap, the cell uses `selection_view`, a
-- 50/50 blend of the two, so the intersection reads as its own tone.
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
--
-- Git deletes are an overlay: a column anchored to a deleted-line gap is
-- drawn as `▁` (red) on empty cells, and as the cell's existing glyph with
-- a red underline on cells that already carry a marker - so a delete next
-- to a cursor or diagnostic doesn't hide it. Differs from the `▄` (red)
-- used by error diagnostics.

local M = {}

-- Color resolution order, per name:
--   1. user override from `opts.colors.<name>`
--   2. fg of a linked highlight group (theme-aware, see THEME_LINK)
--   3. hardcoded fallback below
-- Names with no entry in THEME_LINK skip step 2.
local defaults = {
  colors = {
    cursor     = '#FFFFFF',
    search     = '#FF77AA',
    mark       = '#FFD866',
    selection  = '#6CA0C8',
    viewport   = '#888888',
    error      = '#FC6161',
    warn       = '#FFA348',
    info       = '#67D4F0',
    hint       = '#C792EA',
    git_add    = '#7FCC7F',
    git_change = '#7FAFFF',
    git_delete = '#FC6161',
    base       = '#444444',
    file       = '#AAAAAA',
    dim        = '#444444',
    info_txt   = '#BBBBBB',
  },
}

-- `_dim` names are staged-hunk variants: resolve like their base name, else
-- auto-blend the bright color toward `base` (see color()).
local THEME_LINK = {
  error          = 'DiagnosticError',
  warn           = 'DiagnosticWarn',
  info           = 'DiagnosticInfo',
  hint           = 'DiagnosticHint',
  git_add        = 'GitSignsAdd',
  git_change     = 'GitSignsChange',
  git_delete     = 'GitSignsDelete',
  git_add_dim    = 'GitSignsStagedAdd',
  git_change_dim = 'GitSignsStagedChange',
  git_delete_dim = 'GitSignsStagedDelete',
}

local user_colors = {}

-- Extmark namespaces (from `opts.mark_namespaces`) scanned for bookmarks in
-- mark_lines(). Ids resolved lazily/cached - the owner may create the ns late.
local mark_namespaces = {}
local ns_id_cache = {}
local function ns_id(name)
  if ns_id_cache[name] then return ns_id_cache[name] end
  local id = vim.api.nvim_get_namespaces()[name]
  if id then ns_id_cache[name] = id end
  return id
end

local function hl_fg(group)
  local id = vim.fn.hlID(group)
  if id == 0 then return nil end
  local fg = vim.fn.synIDattr(vim.fn.synIDtrans(id), 'fg#')
  if fg == nil or fg == '' then return nil end
  return fg
end

local function blend_hex(a, b, alpha)
  local function p(s, i) return tonumber(s:sub(i, i + 1), 16) or 0 end
  local ar, ag, ab = p(a, 2), p(a, 4), p(a, 6)
  local br, bg, bb = p(b, 2), p(b, 4), p(b, 6)
  return string.format('#%02X%02X%02X',
    math.floor(ar * alpha + br * (1 - alpha) + 0.5),
    math.floor(ag * alpha + bg * (1 - alpha) + 0.5),
    math.floor(ab * alpha + bb * (1 - alpha) + 0.5))
end

local function color(name)
  if user_colors[name] then return user_colors[name] end
  local link = THEME_LINK[name]
  if link then
    local c = hl_fg(link)
    if c then return c end
  end
  if defaults.colors[name] then return defaults.colors[name] end
  -- Auto-dim fallback for `<base>_dim` names: blend the bright color toward
  -- the bar's empty-cell color so the marker reads as a desaturated echo.
  local base_name = name:match('^(.-)_dim$')
  if base_name then
    return blend_hex(color(base_name), color('base'), 0.45)
  end
end

-- Diagnostic severity (1..4) -> bottom-layer name
local DIAG_BOT = { 'error', 'warn', 'info', 'hint' }

-- Geometry from the last render(), so on_click() can map a click back to a line.
local last     = { left_w = 0, bar_width = 0, total_lines = 1 }

-- Set between a bar press and its release: drag ticks steer the cursor by X
-- (clamped to the bar) regardless of mouse Y.
local dragging = false

local function top_colors()
  local sel, vp = color('selection'), color('viewport')
  return {
    cursor         = color('cursor'),
    search         = color('search'),
    mark           = color('mark'),
    selection      = sel,
    -- Drawn where selection and viewport overlap: a 50/50 blend so the
    -- intersection reads as a distinct tone between the two bands.
    selection_view = blend_hex(sel, vp, 0.5),
    viewport       = vp,
  }
end
local function bot_colors()
  return {
    error          = color('error'),
    warn           = color('warn'),
    git_change     = color('git_change'),
    git_add        = color('git_add'),
    git_change_dim = color('git_change_dim'),
    git_add_dim    = color('git_add_dim'),
    info           = color('info'),
    hint           = color('hint'),
  }
end

local function setup_hl()
  local tc, bc = top_colors(), bot_colors()
  -- `_D`/`_DD` variants add a delete underline (bright/dim) over the glyph, so
  -- a delete next to another marker stays visible. Empty cells use `▁` instead.
  local function add_del(spec, dim)
    return vim.tbl_extend('force', spec,
      { underline = true, sp = color(dim and 'git_delete_dim' or 'git_delete') })
  end
  local function reg(name, spec)
    vim.api.nvim_set_hl(0, name, spec)
    vim.api.nvim_set_hl(0, name .. '_D', add_del(spec, false))
    vim.api.nvim_set_hl(0, name .. '_DD', add_del(spec, true))
  end

  -- Top-only cells: `▀` fg=top_color
  for name, c in pairs(tc) do
    reg('FbnT_' .. name, { fg = c, bold = (name == 'cursor') })
  end
  -- Bottom-only cells: `▄` fg=bottom_color
  for name, c in pairs(bc) do
    reg('FbnB_' .. name, { fg = c })
  end
  -- Both halves: `▀` fg=top, bg=bottom
  for tname, tcol in pairs(tc) do
    for bname, bcol in pairs(bc) do
      reg('FbnT_' .. tname .. '_B_' .. bname,
        { fg = tcol, bg = bcol, bold = (tname == 'cursor') })
    end
  end
  reg('FbnCursorBlock', { fg = color('cursor'), bold = true })
  vim.api.nvim_set_hl(0, 'FbnBase', { fg = color('base') })
  vim.api.nvim_set_hl(0, 'FbnDel', { fg = color('git_delete') })
  vim.api.nvim_set_hl(0, 'FbnDelDim', { fg = color('git_delete_dim') })
  vim.api.nvim_set_hl(0, 'FbnFile', { fg = color('file') })
  vim.api.nvim_set_hl(0, 'FbnDim', { fg = color('dim') })
  vim.api.nvim_set_hl(0, 'FbnInfoTxt', { fg = color('info_txt') })
  vim.api.nvim_set_hl(0, 'FbnErrorTxt', { fg = color('error') })
  vim.api.nvim_set_hl(0, 'FbnWarnTxt', { fg = color('warn') })
end

local function diag_counts(diags)
  local c = { 0, 0, 0, 0 }
  for _, d in ipairs(diags) do c[d.severity] = c[d.severity] + 1 end
  return c
end

-- Set of buffer lines that hold a vim a-z mark, a marks.nvim bookmark, or an
-- extmark in one of `opts.mark_namespaces`.
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
  -- Extmark-based bookmarks: each extmark's row (0-based) is a marked line.
  for _, name in ipairs(mark_namespaces) do
    local id = ns_id(name)
    if id then
      for _, e in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, id, 0, -1, {})) do
        out[e[2] + 1] = true
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

-- Returns four line-keyed maps: unstaged/staged change-add marks and deletes.
-- Pure-delete hunks (added.count==0) anchor on the line before the gap (or 1).
-- Staged hunks come from gitsigns' internal cache - no public API yet.
local function git_marks(bufnr)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then return {}, {}, {}, {} end
  local marks, deletes = {}, {}
  local marks_s, deletes_s = {}, {}

  local function collect(hunks, m_out, d_out)
    for _, h in ipairs(hunks or {}) do
      local added_n   = h.added and h.added.count or 0
      local removed_n = h.removed and h.removed.count or 0
      if added_n > 0 then
        local name = (h.type == 'change') and 'git_change' or 'git_add'
        for lnum = h.added.start, h.added.start + added_n - 1 do
          m_out[lnum] = name
        end
      end
      if removed_n > 0 and added_n == 0 then
        d_out[math.max(1, h.added and h.added.start or 1)] = true
      end
    end
  end

  collect(gitsigns.get_hunks and gitsigns.get_hunks(bufnr) or {}, marks, deletes)

  local cache_ok, gs_cache = pcall(require, 'gitsigns.cache')
  if cache_ok and gs_cache.cache and gs_cache.cache[bufnr] then
    collect(gs_cache.cache[bufnr].hunks_staged, marks_s, deletes_s)
  end

  return marks, deletes, marks_s, deletes_s
end

local function colored_count(n, sev_hl, width)
  local hl = n > 0 and sev_hl or 'FbnDim'
  return string.format('%%#%s#%' .. width .. 'd', hl, n)
end

function M.render()
  local bufnr       = vim.api.nvim_win_get_buf(0)
  local total_lines = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local cursor_lnum = vim.fn.line('.')
  local cursor_col  = vim.fn.col('.')
  local pct         = math.floor((cursor_lnum / total_lines) * 100 + 0.5)

  local view_top    = vim.fn.line('w0')
  local view_bot    = vim.fn.line('w$')

  -- Active visual selection range (any visual mode), else nil. `line('v')`
  -- is the selection's anchor; the cursor is the other end.
  local sel_top, sel_bot
  local m           = vim.fn.mode()
  if m == 'v' or m == 'V' or m == '\22' then
    local anchor = vim.fn.line('v')
    sel_top = math.min(anchor, cursor_lnum)
    sel_bot = math.max(anchor, cursor_lnum)
  end

  local diags                          = vim.diagnostic.get(bufnr)
  local cnt                            = diag_counts(diags)
  local git, git_del, git_s, git_del_s = git_marks(bufnr)
  local marks_by_line                  = mark_lines(bufnr)
  local search_by_line                 = search_lines(bufnr)

  local file                           = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
  if file == '' then file = '[No Name]' end
  local modified      = vim.bo.modified and ' [+]' or ''
  local left_plain    = ' ' .. file .. modified .. '  '
  local left_segment  = string.format('%%#FbnFile# %s%s  ', file, modified)

  local cnt_w         = 3
  local line_w        = math.max(3, #tostring(total_lines))
  local col_w         = 3
  local pct_w         = 3
  local right_plain   = string.format(
    '  %' .. cnt_w .. 'd %' .. cnt_w .. 'd  %' .. line_w .. 'd:%' .. col_w
    .. 'd  %' .. pct_w .. 'd%% ',
    cnt[1], cnt[2], cursor_lnum, cursor_col, pct)
  -- `%#StatusLine#` resets the hl after the bar, else the trailing spaces
  -- inherit the last cell's bg and look like ghost blocks.
  local right_segment = string.format(
    '%%#StatusLine#  %s %s  %%#FbnInfoTxt#%' .. line_w .. 'd:%-' .. col_w
    .. 'd  %' .. pct_w .. 'd%%%% ',
    colored_count(cnt[1], 'FbnErrorTxt', cnt_w),
    colored_count(cnt[2], 'FbnWarnTxt', cnt_w),
    cursor_lnum, cursor_col, pct)

  local bar_width     = vim.o.columns - #left_plain - #right_plain
  if bar_width < 6 then
    last.bar_width = 0
    return left_segment .. '%=' .. right_segment
  end
  last.left_w      = #left_plain
  last.bar_width   = bar_width
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
  local sel_start  = sel_top and lnum_to_col(sel_top)
  local sel_end    = sel_bot and lnum_to_col(sel_bot)

  -- Per-column resolved bottom layer (lower prio number wins).
  local bot        = {}
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
  -- Place staged first with a slightly looser priority so that any unstaged
  -- marker on the same column wins (bright over dim).
  for lnum, name in pairs(git_s) do
    local prio = (name == 'git_change') and 3.5 or 4.5
    put_bot(lnum_to_col(lnum), name .. '_dim', prio)
  end
  for lnum, name in pairs(git) do
    local prio = (name == 'git_change') and 3 or 4
    put_bot(lnum_to_col(lnum), name, prio)
  end

  local search_col = {}
  for lnum in pairs(search_by_line) do search_col[lnum_to_col(lnum)] = true end
  local mark_col = {}
  for lnum in pairs(marks_by_line) do mark_col[lnum_to_col(lnum)] = true end
  -- `del_col[col]` is 'bright' for an unstaged delete, 'dim' for staged.
  -- Unstaged is written last so it overrides a co-located staged marker.
  local del_col = {}
  for lnum in pairs(git_del_s) do del_col[lnum_to_col(lnum)] = 'dim' end
  for lnum in pairs(git_del) do del_col[lnum_to_col(lnum)] = 'bright' end

  local parts = {}
  for col = 1, bar_width do
    local top
    if col == cursor_x then
      top = 'cursor'
    elseif search_col[col] then
      top = 'search'
    elseif mark_col[col] then
      top = 'mark'
    elseif sel_start and col >= sel_start and col <= sel_end then
      -- Blend in the overlap with the viewport band; pure selection outside it.
      top = (col >= view_start and col <= view_end) and 'selection_view'
          or 'selection'
    elseif col >= view_start and col <= view_end then
      top = 'viewport'
    end

    local b = bot[col] and bot[col].name or nil

    local del = del_col[col]
    local hl, ch
    if top == 'cursor' and not b then
      hl, ch = 'FbnCursorBlock', '█'
    elseif top and b then
      hl, ch = 'FbnT_' .. top .. '_B_' .. b, '▀'
    elseif top then
      hl, ch = 'FbnT_' .. top, '▀'
    elseif b then
      hl, ch = 'FbnB_' .. b, '▄'
    elseif del then
      -- Empty cell on a deleted line: use the dedicated `▁` glyph so the
      -- delete is unmistakable even without any other marker.
      hl, ch = (del == 'dim') and 'FbnDelDim' or 'FbnDel', '▁'
    else
      hl, ch = 'FbnBase', '·'
    end
    -- Overlay the delete underline on an existing glyph so the marker survives
    -- (`_DD` is the dim variant for staged deletes).
    if del and ch ~= '▁' then
      hl = hl .. ((del == 'dim') and '_DD' or '_D')
    end
    parts[#parts + 1] = '%#' .. hl .. '#' .. ch
  end

  local bar_segment = '%@FishboneClick@' .. table.concat(parts) .. '%X'
  return left_segment .. bar_segment .. right_segment
end

-- Map a mouse position to a line and jump. `add_jump` pushes a jumplist entry
-- (click yes, drag no); `clamp` clips X to the bar so drag Y can roam freely.
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

-- `%@Fn@` needs a vimscript function name; wrap the Lua callback. Terminal
-- only - Neovide ignores statusline clicks, so setup()'s keymap covers it.
vim.cmd([[
  function! FishboneClick(minwid, clicks, button, mods) abort
    call v:lua.require('fishbone').on_click(
      \ a:minwid, a:clicks, a:button, a:mods)
  endfunction
]])

function M.setup(opts)
  opts = opts or {}
  user_colors = opts.colors or {}
  mark_namespaces = opts.mark_namespaces or {}
  setup_hl()

  vim.opt.statusline = '%!v:lua.require("fishbone").render()'
  vim.opt.laststatus = 3

  -- Neovide doesn't route clicks to %@...@ regions; catch <LeftMouse> on the
  -- statusline row ourselves (detected by screenrow).
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

  -- Drag/release via keymap (both UIs): %@..@ regions don't get these events.
  -- Once a drag starts on the bar, ticks reposition by X (clamped), Y ignored.
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
      'DiagnosticChanged', 'VimResized', 'TextChanged', 'TextChangedI',
      'ModeChanged' },
    { group = group, callback = function() vim.cmd('redrawstatus') end }
  )
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GitSignsUpdate',
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
