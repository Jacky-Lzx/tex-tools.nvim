<img src="assets/icon.svg" width="64" height="64" alt="">

# tex-tools.nvim

A Lua toolkit for writing LaTeX in Neovim, developed in stages and inspired by
[VimTeX](https://github.com/lervag/vimtex)'s editing workflows.

Syntax analysis uses [tree-sitter-latex](https://github.com/latex-lsp/tree-sitter-latex).
[texlab](https://github.com/latex-lsp/texlab) handles completion, diagnostics,
references, formatting, and project management. This plugin provides editing
operations and calls the texlab client already attached to your buffer.

## Phase 1: Context and environment editing

- Detect math and comment contexts for conditions in LuaSnip and other tools.
- Find the innermost environment and jump between `\begin` and `\end`.
- Rename both environment markers in one undo operation and toggle a trailing `*`.
- Use `ae` / `ie` environment text objects in Visual mode or with `d` / `c` / `y`.
- Build and forward search through texlab; check your setup with `:checkhealth tex-tools`.

Supports nested environments, environments on a single line, UTF-8 text,
text and nested formulas inside `\text{}`, comments, and verbatim-like
environments. Editing is refused when an environment cannot be identified,
has incomplete markers, or has mismatched begin/end names.

## Installation

Requires **Neovim ≥ 0.11** and an installed **`latex` Tree-sitter parser**.
With nvim-treesitter, run `:TSInstall latex`. The plugin does not depend on
nvim-treesitter's Lua API or install the parser automatically.

Currently, load the plugin from a local checkout. Example for lazy.nvim:

```lua
{
  dir = "/path/to/tex-tools-nvim", -- Replace with your local checkout path.
  name = "tex-tools.nvim",
  ft = { "tex", "plaintex" },
  opts = {
    mappings = true,
    math_environments = {}, -- e.g. { "myequation" }; starred variants are also recognized.
  },
}
```

For other loading methods, add the repository to `runtimepath`, then call:

```lua
require("tex-tools").setup()
```

Keep your existing Tree-sitter highlighting setup. The plugin leaves indentation,
folding, conceal, and LSP configuration to your existing setup.

## Key mappings and commands

Commands and mappings are registered in `tex` / `plaintex` buffers. Default
mappings are skipped when a global or buffer-local mapping already exists.
Set `mappings = false` to disable the defaults.

- `cse` → `:TexToolsRenameEnvironment [name]`; prompts when the name is omitted.
- `tss` → `:TexToolsToggleEnvironmentStar`, e.g. `equation` ↔ `equation*`.
- `<localleader>lm` → `:TexToolsJumpEnvironment`; jumps from the body or begin marker to end, and from end back to begin.
- `<localleader>ll` → `:TexToolsBuild`; saves the current file, then requests a texlab build.
- `<localleader>lv` → `:TexToolsForwardSearch`; asks texlab to locate the current cursor position in the PDF.
- `ae` / `ie` → selects the whole environment / its body, e.g. `vae`, `yie`, `dae`.

`ie` excludes the begin marker's optional arguments. When markers occupy their
own lines, it also excludes the newlines surrounding the body. An empty body
cancels the operation. `ae` includes the `document` environment. Selecting outer
environments with a count is not supported in this phase.

Star toggling changes the name only; the document class and packages determine
whether the resulting environment exists.

You can also define your own `<Plug>` mappings:

```lua
vim.keymap.set("n", "<leader>te", "<Plug>(TexToolsRenameEnvironment)")
vim.keymap.set({ "x", "o" }, "aE", "<Plug>(TexToolsAroundEnvironment)")
```

See [doc/tex-tools.txt](doc/tex-tools.txt) for all `<Plug>` names and API details.
You can migrate VimTeX workflows gradually. When using both plugins, consider
disabling one plugin's mappings to avoid conflicts.

## texlab configuration

Your existing texlab configuration works as is. texlab manages the compiler,
PDF viewer, root-file discovery, and SyncTeX. Environment editing and context
queries also work without an attached texlab client.

Here is a standalone example using Neovim 0.11's native LSP configuration.
Merge the relevant settings into your existing configuration as needed:

```lua
vim.lsp.config("texlab", {
  cmd = { "texlab" },
  filetypes = { "tex", "plaintex", "bib" },
  root_markers = { ".texlabroot", "texlabroot", ".latexmkrc", "Tectonic.toml", ".git" },
  settings = {
    texlab = {
      build = {
        executable = "latexmk",
        args = { "-pdf", "-interaction=nonstopmode", "-synctex=1", "%f" },
        onSave = false,
      },
      forwardSearch = {
        executable = "zathura",
        args = { "--synctex-forward", "%l:1:%f", "%p" },
      },
    },
  },
})
vim.lsp.enable("texlab")
```

Install `latexmk` and `zathura` separately, or configure your preferred PDF
viewer. Inverse search uses your existing texlab and PDF viewer configuration.

## Lua API

```lua
local tex = require("tex-tools")

tex.in_math()                  -- boolean, optional error message
tex.in_comment()               -- boolean, optional error message
tex.environment()              -- environment table or nil, optional error message
tex.rename_environment("align*")
tex.toggle_environment_star()
tex.jump_environment()
tex.build()
tex.forward_search()

-- Query a specific buffer and position; rows and byte columns are zero-based.
tex.in_math({ bufnr = 3, pos = { 9, 4 } })
```

Context queries do not display notifications and can be called frequently.
They return `false, error` when the parser is unavailable. `environment()` returns
`nil, error` when no usable environment is found. Editing operations return
`true` or `false, error`; for an asynchronous rename, `true` means the input
prompt has opened. Build and forward search return `true, request_id` when the
request is sent, then report the result through a notification.

Example LuaSnip condition:

```lua
local in_math = function() return require("tex-tools").in_math() end
-- s({ trig = "...", condition = in_math }, { ... })
```

Math context follows the syntax tree, recognizing `$...$`, `\(...\)`, `$$...$$`,
`\[...\]`, and math environments supported by the parser. Text regions such as
`\text{...}` leave math mode; nested formulas inside them enter math mode again.
Add custom math environments through `math_environments`. TeX macros are not
expanded.

## Roadmap

1. **Implemented: Foundation** — Context queries, environment detection, renaming, jumps, text objects, texlab requests, and health checks.
2. **Editing** — Command, argument, and formula text objects; adding and removing surrounding environments; math delimiter switching.
3. **Input** — Smart `\item` insertion, context-aware Enter behavior, and completion helpers that compose with existing snippet and pairs plugins.
4. **Navigation** — Section and list-item motions and a table of contents, reusing texlab symbols and definitions where possible.

Each phase is tested against the real parser. Parsing, LSP communication,
compiler processes, and log diagnostics remain the responsibility of
Tree-sitter, Neovim's LSP client, and texlab.

## Development and testing

```sh
stylua --check lua tests
nvim --clean --headless -l tests/run.lua
```

Tests use Neovim and the real `latex` parser without an additional Lua test
framework. If the parser is outside a clean Neovim instance's `runtimepath`,
specify its shared library:

```sh
TEX_TOOLS_TEST_PARSER=/path/to/latex.so nvim --clean --headless -l tests/run.lua
```

Tests cover context boundaries, environment editing, undo, UTF-8 text objects,
actual operator mappings, and texlab request parameter encoding. texlab tests
use a client double and do not start a LaTeX compiler or PDF viewer. Verify
actual builds and PDF navigation with your configured local toolchain.

References: [VimTeX documentation](https://github.com/lervag/vimtex/blob/master/doc/vimtex.txt),
[Tree-sitter LaTeX node definitions](https://github.com/latex-lsp/tree-sitter-latex/blob/master/src/node-types.json),
and [texlab protocol extensions](https://github.com/latex-lsp/texlab/wiki/Protocol-Extensions).
