# classlayout.nvim

See where your bytes go without leaving Neovim.

<img width="1600" height="696" alt="demo" src="https://github.com/user-attachments/assets/fff3789c-f7a3-469e-bc7c-3a362b5486b8" />

Visualize C/C++ struct and class memory layouts — field offsets, padding,
alignment — in a floating window. Hover over a type or variable and see
exactly how the compiler laid it out.

## Features

- Works on structs, classes, unions, and STL types
- Resolves variables to their underlying type via clangd
- Auto-detects compiler flags from `compile_commands.json` or `compile_flags.txt`
- Cached — first lookup compiles, subsequent lookups are instant

## Requirements

- Neovim >= 0.10
- clang in PATH
- clangd for type resolution from variables and qualified types

## Install

```lua
-- lazy.nvim
{
  "J-Cowsert/classlayout.nvim",
  ft = { "c", "cpp" },
  opts = {},
}
```

## Configuration

Default config — override what you need:

```lua
require("classlayout").setup({
  keymap = "<leader>cl",
  compiler = "clang",
  args = {},
  compile_commands = true,
})
```

## Usage

Cursor on a type name or variable. Press `<leader>cl` or `:ClassLayout`.
Press `q` to close.

The layout is based on the saved file — save before invoking.
