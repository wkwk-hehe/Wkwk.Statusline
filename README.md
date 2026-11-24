# Wkwk.Statusline

A simple Lua statusline for Neovim. Heavily inspired by `modeline.nvim`

## Install

Add the plugin to your plugin manager and load it at startup.

Example with `lazy.nvim`:

```lua
{
  "wkwk-hehe/Wkwk.Statusline",
  name = "Wkwk.Statusline",
  config = function()
    require("wkwk.statusline").setup()
  end,
}
```

Git status requires [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim).
Other sections work without it.
