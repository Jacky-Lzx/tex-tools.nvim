# tex-tools.nvim

<img src="assets/icon.svg" width="64" height="64" alt="">

LaTeX structural editing, navigation and language-server build workflows.

## Features

- Edit environments, commands, tables, matrices and section levels.
- Navigate an outline and use syntax-aware text objects and contexts.
- Integrate optional conceal, PDF viewing and formula previews.

## Requirements

Neovim **0.11+**. Requires the `latex` Tree-sitter parser. Configure texlab or texquill separately for compilation and forward search. Media previews optionally use image-tools.nvim.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/tex-tools.nvim",
  main = "tex-tools",
  opts = { lsp = "texlab", mappings = false },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("tex-tools").setup({ lsp = "texlab", mappings = false })
```

## Usage

```vim
:TexToolsOutline
```

## Documentation

- [Complete reference](doc/tex-tools.txt) — `:help tex-tools`.
- [Workflow and integration guide](doc/guide.md).
- Diagnose availability with `:checkhealth tex-tools`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.
