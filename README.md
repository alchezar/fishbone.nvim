# fishbone.nvim

A horizontal "fishbone" position bar for Neovim's global statusline.

Renders the whole file across the bottom row of the screen: every buffer
line maps to a column on the bar. Like a one-line minimap.

## Layout

```
<file path> [+]   <bar>   <E> <W>  L:C  P%
```

Each cell composes a top half (overview) and a bottom half (signals):

**Top half** (`▀`, highest wins):

| Layer    | Color  | Source                              |
|----------|--------|-------------------------------------|
| cursor   | white  | current cursor line                 |
| search   | pink   | lines matching the active `/` pattern |
| mark     | yellow | vim a-z marks, marks.nvim bookmarks |
| viewport | silver | lines currently visible on screen   |

**Bottom half** (`▄`, highest wins):

| Layer       | Color  |
|-------------|--------|
| error       | red    |
| warn        | orange |
| git change  | blue   |
| git add     | green  |
| info        | cyan   |
| hint        | purple |

Cells with both halves use `▀` with fg=top, bg=bottom. Cursor with no
bottom layer uses `█`. Empty cells use `·`.

## Setup

```lua
require('fishbone').setup({
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
  },
})
```

Sets `laststatus=3` and installs a `%!` statusline expression.

## Soft dependencies

- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) - git add/change markers.
- [marks.nvim](https://github.com/chentoast/marks.nvim) - numbered bookmarks (vim a-z marks work without it).
