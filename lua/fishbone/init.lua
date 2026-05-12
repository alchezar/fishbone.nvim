-- Horizontal "fishbone" position bar. Layout:
--   <file path> [+]   <bar fills the rest of the row>
-- The bar maps every file line to a column. One cell per priority:
--   cursor   white   █
--   git_chg  blue    █
--   git_add  green   █
--   viewport silver  █
--   empty    dark    ·

local M = {}

local config = {
  colors = {
    cursor     = '#FFFFFF',
    viewport   = '#888888',
    git_add    = '#7FCC7F',
    git_change = '#7FAFFF',
    base       = '#444444',
    file       = '#AAAAAA',
  },
}

local function setup_hl()
  local c = config.colors
  vim.api.nvim_set_hl(0, 'FbnCursor',    { fg = c.cursor, bold = true })
  vim.api.nvim_set_hl(0, 'FbnViewport',  { fg = c.viewport })
  vim.api.nvim_set_hl(0, 'FbnGitAdd',    { fg = c.git_add })
  vim.api.nvim_set_hl(0, 'FbnGitChange', { fg = c.git_change })
  vim.api.nvim_set_hl(0, 'FbnBase',      { fg = c.base })
  vim.api.nvim_set_hl(0, 'FbnFile',      { fg = c.file })
end

-- lnum -> 'git_add' | 'git_change' for git-changed lines.
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

function M.render()
  local bufnr = vim.api.nvim_win_get_buf(0)
  local total_lines = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local cursor_lnum = vim.fn.line('.')
  local view_top = vim.fn.line('w0')
  local view_bot = vim.fn.line('w$')

  local git = git_marks(bufnr)

  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
  if file == '' then file = '[No Name]' end
  local modified = vim.bo.modified and ' [+]' or ''
  local left_plain = ' ' .. file .. modified .. '  '
  local left_segment = string.format('%%#FbnFile# %s%s  ', file, modified)

  local bar_width = vim.o.columns - #left_plain
  if bar_width < 6 then return left_segment end

  local function lnum_to_col(lnum)
    local col = math.floor(((lnum - 1) / math.max(1, total_lines - 1))
                           * (bar_width - 1)) + 1
    if col < 1 then return 1 end
    if col > bar_width then return bar_width end
    return col
  end

  local cursor_x   = lnum_to_col(cursor_lnum)
  local view_start = lnum_to_col(view_top)
  local view_end   = lnum_to_col(view_bot)

  local git_col = {}
  for lnum, name in pairs(git) do
    git_col[lnum_to_col(lnum)] = name
  end

  local parts = {}
  for col = 1, bar_width do
    local hl, ch
    if col == cursor_x then
      hl, ch = 'FbnCursor', '█'
    elseif git_col[col] == 'git_change' then
      hl, ch = 'FbnGitChange', '█'
    elseif git_col[col] == 'git_add' then
      hl, ch = 'FbnGitAdd', '█'
    elseif col >= view_start and col <= view_end then
      hl, ch = 'FbnViewport', '█'
    else
      hl, ch = 'FbnBase', '·'
    end
    parts[#parts+1] = '%#' .. hl .. '#' .. ch
  end

  return left_segment .. table.concat(parts)
end

function M.setup(opts)
  opts = opts or {}
  if opts.colors then
    config.colors = vim.tbl_extend('force', config.colors, opts.colors)
  end
  setup_hl()

  vim.opt.statusline = '%!v:lua.require("fishbone").render()'
  vim.opt.laststatus = 3

  local group = vim.api.nvim_create_augroup('Fishbone', { clear = true })
  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'WinScrolled', 'BufEnter',
      'VimResized', 'TextChanged', 'TextChangedI' },
    { group = group, callback = function() vim.cmd('redrawstatus') end }
  )
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'GitSignsUpdate',
    callback = function() vim.cmd('redrawstatus') end,
  })
  vim.api.nvim_create_autocmd('ColorScheme',
    { group = group, callback = setup_hl })
end

return M
