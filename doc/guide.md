# Workflow and integration guide

[Quick start](../README.md) · [Complete reference](tex-tools.txt)

Configuration defaults and API contracts are maintained in the help reference.
The examples here illustrate particular workflows.

## Installation details

Requires **Neovim ≥ 0.11** and the **`latex` Tree-sitter parser**. Configure
your language server separately for compilation and PDF viewing/forward search.

With lazy.nvim:

```lua
{
  "Jacky-Lzx/tex-tools.nvim",
  ft = { "tex", "plaintex" },
  opts = {
    lsp = "texlab",             -- "texlab" or "texquill".
    mappings = false,
    overwrite_mappings = false, -- Replace conflicting mappings when true.
    smart_enter = false,        -- List-aware Insert-mode Enter.
    conceal = false,            -- Optional LaTeX conceal.
    math_environments = {},     -- Additional math environment names.
    formula_preview = false,    -- Opt in to formula PNG previews via image-tools.nvim.
  },
}
```

With other plugin managers, add the plugin to `runtimepath` and call
`require("tex-tools").setup()`. Set `vim.g.maplocalleader` before loading.
Run `:checkhealth tex-tools` to check dependencies and project settings.

See `:help tex-tools.txt` or [the reference](tex-tools.txt) for all options,
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

Set `viewer = { focus = false }` to keep focus in Neovim when opening Skim/Pagewing
or performing forward search with texquill. The default is `true`.

For [Pagewing](https://github.com/Jacky-Lzx/pdf-viewer), configure:

```lua
require('tex-tools').setup({
  lsp = 'texquill',
  viewer = { method = 'pagewing', executable = '/path/to/pagewing', focus = false },
})
```

Compile successfully, then use `:TexToolsView` or `:TexToolsForwardSearch`.
Ctrl/Cmd+click in Pagewing sends PDF coordinates back to the owning Neovim session,
which uses its existing TeXquill client for reverse search. Both directions use
server queries; Pagewing does not run another SyncTeX query in this mode. After
restarting Neovim or its LSP, run View/ForwardSearch again to associate the PDF.

The texquill backend delegates builds, cancellation, status, root selection,
artifact cleanup and SyncTeX queries to `latex.*` server commands. The outline
uses LSP symbols and document links. PDF/log paths come from server build
results, so compile before viewing them. Pagewing and Skim consume returned page/coordinates;
Zathura opens the returned page. Source callbacks remain available for both.
Use native `vim.lsp.buf` actions for completion, rename, formatting and code
actions; local structural edits remain available in this plugin.

## Mappings

Default user mappings are disabled. Bind commands or `<Plug>` endpoints in your
filetype configuration; `mappings = true` explicitly enables the suggested
preset below. Preset mappings are buffer-local to `tex` and `plaintex` files. Existing mappings are
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

## Image previews

LaTeX image and formula previews share one selection controller. Image previews
are enabled by default (`image_preview = false` disables them); the optional
image-tools.nvim backend loads only after an image is selected. Formula previews
remain opt-in. tex-tools owns cursor/range selection, local path resolution and
formula compilation; image-tools owns layout, conversion, uploads and display.

`:TexToolsPreview` / `require('tex-tools').preview()` selects the reference under
the cursor, falling back to the first image/formula covering the line. Literal
`\includegraphics` supports multiline commands/options, starred forms and
`\detokenize` filenames. Comments, literal environments, inline verbatim,
definitions, dynamic macros and split filenames are excluded. Preceding literal
`\graphicspath` directories and omitted PDF/PNG/JPG/JPEG extensions are resolved.
The default base is the document directory (or an existing `b:vimtex.root`);
`image_preview.root` accepts a string/function for a project-specific base.

```lua
require('tex-tools').setup({
  image_preview = { enabled = true, delay = 100, max_lines = 64, max_bytes = 16384 },
  formula_preview = { enabled = true },
})
```

`image_preview.layout` overrides image-tools float settings. `image_at({bufnr?,
pos?})` returns a read-only snapshot with `path`, `source`, zero-based byte
`range`, `kind` and a file-version `key`, without loading image-tools. A LaTeX
Tree-sitter parser is required; recognition does not fall back to plain paths.
Images do not inherit the document's preamble or expand macros. References in
other included files are not searched for graphicspath declarations.

While automatic previews are active, tex-tools sets
`b:image_tools_preview_owner = 'tex-tools'`, preventing a second image-tools
controller from selecting LaTeX references. Disabling both preview types releases
ownership. The existing formula toggle controls the shared automatic controller;
`formula_info()` additionally reports `kind` and `images_enabled`.
Use `TexToolsPreview` for unified manual previews; `TexToolsFormulaPreview` remains
formula-only. Image insertion, asset inspection and reference rewriting remain
in image-tools.

## Formula previews

tex-tools detects LaTeX formulas with the same Tree-sitter semantics as its
editing commands, compiles them to transparent PNGs and displays them through
the public `image_tools.float()` API. Install image-tools.nvim with `float()`
support, Neovim >= 0.12, `latex`, `dvipng` and amsmath/amssymb. The feature is
optional and disabled by default; LaTeX editing does not require image-tools.

```lua
require('tex-tools').setup({
  formula_preview = {
    enabled = true,
    delay = 100,
    density = 360,
    preamble = '\\usepackage{amsmath,amssymb}',
    -- layout = { position = 'bottom_right', right_padding = 2 },
  },
})
```

For lazy.nvim add `dependencies = { 'image-tools.nvim' }` to the tex-tools spec
when enabling previews, using the name from your image-tools installation.
Move onto a formula or use `:TexToolsFormulaPreview`. `:TexToolsFormulaClose`
cancels/cleans the current preview; `:TexToolsFormulaToggle` controls automatic
previews. `:TexToolsFormulaReload`, `:TexToolsFormulaInfo` and
`:TexToolsFormulaClearCache` refresh, inspect or clear unused compiled PNGs.
The cursor selects a covering formula, otherwise the first formula covering its
line. Comments, inline verbatim, literal environments and incomplete formulas
are excluded. Movement within one formula retains work; leaving, editing its
source or changing owner cancels stale work. Manual preview bypasses the delay.

Rendering uses a private standalone article and the configured `preamble`;
project preambles, custom macros and equation counters are not inherited.
Higher DPI improves sampling while logical display size stays at a 180-DPI
baseline. Image-tools owns layout (including scrollbar space/right padding),
uploads and window resources; tex-tools owns compile workers and PNG leases.
Markdown formula handling remains in image-tools and is unchanged.

Read-only `formula_at({bufnr?, pos?})` returns source, zero-based byte `range`
and a content key. `render_formula(source, options, callback)` compiles without
image-tools or an LSP and returns cancellation; callback receives `(error, image)`.
An image has `path`, pixel dimensions, `display_size` and idempotent `release()`;
retain its lease until display closes. See `:help tex-tools-formula` for limits.

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

Preview controller setup waits for the first TeX buffer or an explicit preview
API call. Calling `setup()` in an empty or unrelated-language session does not
load the controller; `formula_info()` and closing an inactive preview stay cold.
Automatic previews still initialize when the first TeX buffer attaches. Formula
compilation and the optional display backend remain deferred to a real preview.

## Read-only snippet contexts

`in_environment(names, opts)` checks exact names, including starred and nested environments, outside comments/literal content. `document_class(opts)` returns the class declared in that buffer. Both accept `bufnr`; environment queries also accept a zero-based byte `pos`. Unavailable parsers return an error as the second result.

Snippet predicates can pass `{ fallback = true }` to `in_math` and `in_environment`. If the structural parser is unavailable, a lexical fallback handles delimiters, configured math environments, comments, literal blocks and nested text/math. Default query error semantics are unchanged.
