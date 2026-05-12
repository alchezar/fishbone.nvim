# fishbone.nvim

A horizontal "fishbone" position bar for Neovim's global statusline.

Renders the whole file across the bottom row of the screen: every buffer
line maps to a column on the bar. Like a one-line minimap.

## Markers

| Glyph | Meaning           |
|-------|-------------------|
| `█`   | cursor / viewport / git hunk |
| `·`   | empty             |

Cursor wins over git, git wins over viewport.

## Setup

```lua
require('fishbone').setup({
  colors = {
    cursor     = '#FFFFFF',
    viewport   = '#888888',
    git_add    = '#7FCC7F',
    git_change = '#7FAFFF',
    base       = '#444444',
  },
})
```

Sets `laststatus=3` and installs a `%!` statusline expression.

## Soft dependencies

- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) - git add/change markers.
