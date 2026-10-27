<img src="assets/icon.svg" width="64" height="64" alt="">

# tex-tools.nvim

LaTeX editing for Neovim: structural edits, text objects, navigation, tables,
outline, optional conceal, and snippet context queries using Tree-sitter.
Compilation and PDF forward search use your selected texlab or texquill client; PDF viewing
and native inverse search are also supported.

## Installation

Requires **Neovim ≥ 0.11** and the **`latex` Tree-sitter parser**. Configure
your language server separately for compilation and PDF viewing/forward search.

With lazy.nvim:

```lua
{
  "Jacky-Lzx/tex-tools.nvim",
  ft = { "tex", "plaintex" },
  opts = {
    lsp = "texlab",             -- "texlab" or "texquill".
    mappings = true,
    overwrite_mappings = false, -- Replace conflicting mappings when true.
    smart_enter = false,        -- List-aware Insert-mode Enter.
    conceal = false,            -- Optional LaTeX conceal.
    math_environments = {},     -- Additional math environment names.
  },
}
```

With other plugin managers, add the plugin to `runtimepath` and call
`require("tex-tools").setup()`. Set `vim.g.maplocalleader` before loading.
Run `:checkhealth tex-tools` to check dependencies and project settings.

See `:help tex-tools.txt` or [the reference](doc/tex-tools.txt) for all options,
commands, `<Plug>` mappings, and Lua APIs.

To use [TeXquill](https://github.com/Jacky-Lzx/texquill), configure its Neovim client as `texquill`
and select it in this plugin:

```lua
vim.lsp.config("texquill", {
  cmd = { "texquill", "--stdio" },
  filetypes = { "tex", "plaintex", "bib", "bst" },
  root_markers = { ".texquill.json", ".latexmkrc", "latexmkrc", ".git" },
  init_options = { build = { onSave = false } },
})
vim.lsp.enable("texquill")
require("tex-tools").setup({ lsp = "texquill" })
```

Set `viewer = { focus = false }` to keep focus in Neovim when opening Skim
or performing forward search with texquill. The default is `true`.

The texquill backend delegates builds, cancellation, status, root selection,
artifact cleanup and SyncTeX queries to `latex.*` server commands. The outline
uses LSP symbols and document links. PDF/log paths come from server build
results, so compile before viewing them. Skim consumes returned page/coordinates;
Zathura opens the returned page. Source callbacks remain available for both.
Use native `vim.lsp.buf` actions for completion, rename, formatting and code
actions; local structural edits remain available in this plugin.

## Mappings

Mappings are buffer-local to `tex` and `plaintex` files. Existing mappings are
preserved unless `overwrite_mappings = true`. Disabling overwrite restores
replaced mappings; `mappings = false` disables default keys while keeping
commands and `<Plug>` mappings available. With `smart_enter = true`, overwrite
also applies to Insert-mode `<CR>`.

Normal mode unless stated otherwise. In abbreviated entries, `<localleader>`
applies to every key.

| Key                             | Action                                              |
| ------------------------------- | --------------------------------------------------- |
| `<localleader>lcr` / `lcd`      | Rename / unwrap a command                           |
| `<localleader>lcs`              | Surround a line or Visual selection with a command  |
| `<localleader>lEr` / `lEt`      | Rename an environment / toggle its star             |
| `<localleader>lEs` / `lEd`      | Surround lines with / unwrap an environment         |
| `<localleader>lm`               | Jump between environment begin/end markers          |
| `<localleader>lf`               | Switch dollar/backslash math delimiters             |
| `<localleader>ldc` / `ldd`      | Change / remove math brackets                       |
| `<localleader>ldt` / `ldm`      | Toggle bracket sizing / jump to matching bracket    |
| `<localleader>li`               | Insert a sibling `\item`                            |
| `<localleader>lt`               | Open the section outline                            |
| `<localleader>ll` / `lv`        | Build / PDF forward search                          |
| `<localleader>lk` / `lK` / `lg` | Cancel current/all clients' builds / show status    |
| `<localleader>lo` / `lq` / `le` | Live compiler output / full log / diagnostics       |
| `<localleader>lc` / `lC`        | Clean auxiliary files / all artifacts including PDF |
| `]]` / `[[`                     | Next / previous section                             |
| `]i` / `[i`                     | Next / previous list item                           |
| `]e` / `[e`                     | Next / previous environment                         |
| `]m` / `[m`                     | Next / previous formula                             |
| `]t` / `[t`                     | Next / previous table cell                          |
| `]]` (Insert)                   | Insert the nearest missing closing marker           |

Text objects work in Visual and operator-pending modes. Counts select enclosing
depth where supported; navigation supports counts and jump history.
Cursor-based rename, unwrap, and toggle edits support `.` and single-step undo.

| Around / inside | Target                      |
| --------------- | --------------------------- |
| `ae` / `ie`     | Environment                 |
| `ac` / `ic`     | Command call / command name |
| `aa` / `ia`     | Curly or bracket group      |
| `a$` / `i$`     | Formula                     |
| `ad` / `id`     | Math brackets               |
| `ai` / `ii`     | List item                   |
| `aP` / `iP`     | Section and subsections     |
| `at` / `it`     | Table cell                  |

Custom mappings can use individual `<Plug>` names:

```lua
vim.keymap.set("n", "<localleader>lr", "<Plug>(TexToolsRenameEnvironment)")
```

## Commands

All command names begin with `TexTools` (for example, `:TexToolsMain`).

| Command                                   | Purpose                                              |
| ----------------------------------------- | ---------------------------------------------------- |
| `Main [path\|select\|reset]` / `Info`     | Select the main file / inspect project paths         |
| `Build` / `BuildOnSave [on\|off\|toggle]` | Compile / control automatic builds                   |
| `Compiler [name\|toggle]`                 | Query or switch configured `build.profiles`          |
| `View` / `ForwardSearch`                  | Open the PDF / jump to the source position in it     |
| `InverseSearch [skim\|zathura]`           | Show the native inverse-search callback              |
| `Outline[!] [query]`                      | Search sections in the current file or project (`!`) |
| `ToggleCommandStar` / `ToggleFraction`    | Toggle command stars / fraction notation             |
| `ConvertMath {target}` / `ToggleMathMode` | Convert math environments / inline-display mode      |
| `InsertRow` / `DeleteRow`                 | Edit table rows                                      |
| `InsertColumn` / `DeleteColumn`           | Edit table columns                                   |
| `PromoteSection` / `DemoteSection`        | Shift section levels and descendant headings         |

Main-file discovery supports `% !TeX root`, `build.main_file`, and explicit
`:TexToolsMain` selection. Compiler profiles and output-directory configuration
are covered in `:help tex-tools-compiler-profiles`. For native compiler error
diagnostics with texlab, omit `-file-line-error` from compiler arguments so it can parse
the standard TeX log format.

PDF synchronization requires SyncTeX support in both compiler and viewer.
Zathura launched through `:TexToolsView` gets its inverse callback automatically.
For Skim, run `:TexToolsInverseSearch skim` and copy **Command** and **Arguments**
into **Settings → Sync → Custom**. The callback works across Neovim restarts;
see `:help tex-tools-viewer` for setup and platform details.

## Conceal and snippet contexts

Conceal supports accents, symbols, citations, math delimiters, and formatting
wrappers. Enable it and set Neovim's display options:

```lua
require("tex-tools").setup({ conceal = true })
vim.opt.conceallevel = 2
```

Categories and custom symbols are configurable; see `:help tex-tools-conceal`.
Disable overlapping VimTeX or legacy syntax conceal rules when using it.

Read-only Lua queries include `in_math()`, `in_comment()`, `in_subscript()`,
`in_superscript()`, `in_numerator()`, `in_denominator()`, and `in_table_cell()`:

```lua
local in_math = function() return require("tex-tools").in_math() end
-- Use in_math as a snippet condition.
```

## Development

```sh
stylua --check lua tests
nvim --clean --headless -l tests/run.lua
```

The tests require the `latex` Tree-sitter parser. `--clean` excludes user
directories from the runtime path, so set `TEX_TOOLS_TEST_PARSER=/path/to/latex.so`
when using a parser installed in your user data directory.

On macOS, with the parser installed in Neovim's default user site directory:

```sh
TMPDIR=/private/tmp \
TEX_TOOLS_TEST_PARSER="$HOME/.local/share/nvim/site/parser/latex.so" \
nvim --clean --headless -l tests/run.lua
```

Adjust the parser path to match your installation. `TMPDIR=/private/tmp` avoids
failures caused by the macOS `/var` to `/private/var` symlink: temporary fixture
paths and Neovim buffer names can otherwise differ even when they refer to the
same file. These environment variables apply only to this command.

Optional integration check: `nvim --clean --headless -l tests/live_latexmk.lua`
(requires texlab and latexmk).

For texquill (requires latexmk and SyncTeX):

```sh
TEX_TOOLS_TEXQUILL=/path/to/texquill \
  nvim --clean --headless -i NONE -l tests/live_texquill.lua
```
