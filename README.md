<img src="assets/icon.svg" width="64" height="64" alt="">

# tex-tools.nvim

Lua tools for writing LaTeX in Neovim, inspired by [VimTeX](https://github.com/lervag/vimtex).
Provides structural editing, text objects, navigation, optional conceal, list input, and snippet
context queries using [Tree-sitter](https://github.com/latex-lsp/tree-sitter-latex).
Build and PDF forward search use your existing texlab client; texlab handles
completion, diagnostics, references, and formatting.

## Installation

Requires **Neovim ≥ 0.11** and the **`latex` Tree-sitter parser** (for example,
`:TSInstall latex` with nvim-treesitter). Configure texlab separately if you
want build and forward search.

Load this local checkout with lazy.nvim:

```lua
{
  dir = "/path/to/tex-tools-nvim",
  ft = { "tex", "plaintex" },
  opts = {
    mappings = true,
    smart_enter = false,    -- Optional list-aware Insert-mode Enter.
    conceal = false,        -- Optional visible-range LaTeX conceal.
    math_environments = {}, -- Additional math environments; stars are recognized.
  },
}
```

With other plugin managers, add the plugin to `runtimepath` and call
`require("tex-tools").setup()`. Set `vim.g.maplocalleader` before loading.
Existing mappings are preserved; `mappings = false` keeps commands and
`<Plug>` mappings available. Check dependencies with `:checkhealth tex-tools`.

## Default keys

Keys use `<localleader>l`, grouped by `c` (commands), `e` (environments),
and `d` (math brackets). Normal mode unless stated otherwise.

| Key | Action |
| --- | --- |
| `<localleader>lcr` / `lcd` | Rename / unwrap a command |
| `<localleader>lcs` | Surround a line or Visual selection with a command |
| `<localleader>ler` / `let` | Rename an environment / toggle its star |
| `<localleader>les` / `led` | Surround lines with / unwrap an environment |
| `<localleader>lm` | Jump between environment begin/end markers |
| `<localleader>lf` | Switch `$…$` ↔ `\(…\)` or `$$…$$` ↔ `\[…\]` |
| `<localleader>ldc` / `ldd` | Change / remove math brackets |
| `<localleader>ldt` / `ldm` | Toggle `\left`/`\right` sizing / jump to the matching bracket |
| `<localleader>li` | Insert a sibling `\item` (Normal / Insert) |
| `<localleader>ll` / `lv` | Build / PDF forward search through texlab |
| `<localleader>lk` / `lK` | Cancel builds in the current / all texlab clients |
| `<localleader>lg` | Show build status |
| `<localleader>lo` / `lq` / `le` | Live compiler output / full log / texlab diagnostics |
| `<localleader>lc` / `lC` | Clean auxiliary files / all artifacts including PDF |
| `]]` / `[[` | Next / previous section |
| `]i` / `[i` | Next / previous item at the current list level |
| `]e` / `[e` | Next / previous environment opening |
| `]m` / `[m` | Next / previous formula opening |

In paired entries, `<localleader>` applies to both keys. Environment surrounds
also work in Visual mode and operate on whole lines. Navigation supports
counts, jump history, and fold opening.

### Text objects

Use in Visual mode or with operators such as `d`, `c`, and `y`.

| Around / inside | Target |
| --- | --- |
| `ae` / `ie` | Environment including markers / body |
| `ac` / `ic` | Command call / name without the backslash |
| `aa` / `ia` | Curly or bracket group / contents |
| `a$` / `i$` | Formula including delimiters / body |
| `ad` / `id` | Math brackets including size commands / contents |
| `ai` / `ii` | List item including marker and label / body |

Counts select enclosing depth: `d2ac` deletes the second enclosing command,
`2ai` selects the parent item. Bracket jumps also count enclosing depth;
section/item/environment/formula motions count successive targets.
Whole-line `ai` selections are linewise; other objects are characterwise.
An empty inner object or unavailable depth cancels the operator.

### Lists and repeat

Lists support `itemize`, `enumerate`, and `description`, including nested lists
and continuation paragraphs. In description lists, insertion starts inside
the new label. Enable `smart_enter` to split nonempty items with Enter;
other contexts use native Enter.

Cursor-based rename, unwrap, and toggle edits support `.` and single-step
undo. Surrounds and list input do not register structural repeats;
text-object operators use native repeat behavior.

## Compilation

`:TexToolsMain` shows the main file; `:TexToolsMain path/to/main.tex` selects it
for the current texlab client/session. Relative paths use the LSP root.
`:TexToolsMain select` opens a file prompt; `:TexToolsMain reset` restores
`build.main_file` or source/root-directive discovery. Selection is shared by
buffers in that client, and refuses changes during compilation/cleanup.
`:TexToolsInfo` shows the main file, working directory, compiler and artifact
paths. Lua: `main_file(path?)` returns `true, path` or `false, error`; pass `false`
to reset. `project_info()` returns a snapshot or `nil, error`.

Manual builds target the resolved main document and save a modified main buffer
as well as the current file. Texlab's automatic builds still use its dependency
graph. With build-on-save enabled, save a modified child first or disable
automatic compilation before explicitly building a different main document.

`:TexToolsBuild` saves the current file and requests a texlab build. A second
build is rejected while that client has an active compilation. If saving already
triggers texlab's `build.onSave`, no duplicate build request is sent.

Use `:TexToolsCancelBuild`, `:TexToolsCancelAllBuilds`, and `:TexToolsBuildStatus`
to control or inspect compilation. Cancellation affects builds in the selected
texlab server instance, rather than a single buffer. `:TexToolsBuildOnSave
[on|off|toggle]` changes automatic compilation for that client's current session;
the compiler and other texlab settings are preserved.

`require("tex-tools").build_status()` returns a snapshot with `phase`, `uri`,
`on_save`, optional `result` and `elapsed` seconds. Manual builds report the
compiler's result. Automatic builds without an explicit response report
`finished`; their diagnostics provide error details. Native LSP progress handling
remains available to statuslines and progress plugins.
The snapshot also includes the currently configured `compiler` executable and,
when settings match a configured profile, its `profile` name.

### Compiler profiles

Define optional profiles in the plugin configuration:

```lua
require("tex-tools").setup({
  build = {
    profiles = {
      latexmk = {
        executable = "latexmk",
        args = {
          "-pdf", "-synctex=1", "-interaction=nonstopmode",
          "-file-line-error", "%f",
        },
      },
      tectonic = {
        executable = "tectonic",
        args = {
          "-X", "compile", "%f", "--synctex",
          "--keep-logs", "--keep-intermediates",
        },
      },
    },
  },
})
```

Use `:TexToolsCompiler latexmk`, `:TexToolsCompiler tectonic`, or
`:TexToolsCompiler toggle`. With no argument, the command shows the current
profile and executable. Profile names support completion. `toggle` cycles names
in alphabetical order, starting with the first when current settings match none.
For XeLaTeX, define another profile with latexmk's `-xelatex` instead of `-pdf`.

Profiles default to `{}`. Loading or repeating `setup()` does not select a
compiler; your existing texlab configuration remains the startup default.
Switching updates the attached client's settings without restarting texlab or
starting a build. It affects every buffer sharing that client for the current
session; it does not persist changes to your configuration files.

Each profile requires `executable` and a string list `args`. Optional fields are
`auxDirectory`, `logDirectory`, `pdfDirectory`, and `filename` (a basename).
Switching replaces the entire argument list and clears any of these four
overrides omitted by the new profile. Put shared output overrides in every
profile that needs them. Directory settings tell texlab where to find artifacts;
also set the compiler's output arguments as needed. These settings are used by
the existing log and cleanup commands. Other texlab settings, including
`onSave`, `forwardSearchAfter`, and PDF forward search, are preserved.

Switching requires an available local executable and refuses an active build or
cleanup. A failed configuration notification restores local settings. The LSP
notification has no server acknowledgement: success means the update was sent;
texlab applies it asynchronously. Lua:
`require("tex-tools").compiler(name?)` returns `true, snapshot` or `false, error`;
omit `name` to query. The snapshot contains `profile` (when matched), `executable`,
`args` (when explicitly set), and the sorted available `profiles` names. No
default key mapping is installed for compiler switching.

### Output and cleanup

`:TexToolsBuildOutput` opens bounded live compiler output without replacing
existing LSP log handlers. In that window, `q` closes it and `F` toggles following
new lines. Output is reset for each build; no window opens automatically.
`:TexToolsLog [path]` opens the full `.log` read-only. Without a path, the main
file is resolved through `% !TeX root` directives or `build.main_file` (relative
to the LSP root), with `\documentclass` identifying a standalone main file.
Ambiguous child files require one of these explicit roots.

`:TexToolsErrors` fills quickfix with the current texlab client's errors and
warnings; `:TexToolsErrors!` includes errors only. Other diagnostic providers
are excluded. The list opens only when requested and nonempty.

```lua
require("tex-tools").setup({
  build = { output_lines = 2000, main_file = false },
})
```

Log discovery respects texlab's `logDirectory`, common output/jobname arguments,
and root markers. Complex `.latexmkrc` output paths are not evaluated; configure
texlab directories explicitly or pass a log path. The Lua APIs are
`build_output()`, `build_log(path?)`, and
`build_errors({ errors_only = false, open = false })`.

`:TexToolsClean` removes auxiliary files; `:TexToolsCleanFull` also removes the
PDF. For latexmk, these delegate to texlab's `cleanAuxiliary` / `cleanArtifacts`
commands. For Tectonic's `compile` command, cleanup removes only exact main-file
artifacts from the resolved directories: `.aux`, `.out`, `.toc`, `.lof`, `.lot`,
`.fls`, `.nav`, `.snm`, `.vrb`, `.synctex.gz`, and `.log`. `.bbl`, bibliography,
source and unrelated files are retained. The default directory for Tectonic is
the main file's directory; `--outdir` / `-o` and texlab's directory settings are
respected. Directory trees are never removed; leaf symlinks are unlinked.
Cleanup refuses active builds, unknown main files, custom compiler backends and
Tectonic project `build` / `watch` commands. Lua: `clean()` / `clean(true)` return
`true, request_id` for latexmk (completion notifies), or `true, removed_count`
for Tectonic; failures return `false, error`.

Builds use texlab's process lifecycle. Independent persistent `latexmk -pvc`
management and selected-region compilation are not provided.

## Conceal

Conceal is editor rendering; texlab does not provide it. Enable it with:

```lua
require("tex-tools").setup({ conceal = true })
vim.opt.conceallevel = 2
-- Optional: keep conceal on the cursor line in Normal mode.
vim.opt.concealcursor = "nc"
```

`conceal = true` enables these eight categories. Pass a table to disable any
category, for example `conceal = { cites = false, styles = false }`.

| Option | Examples |
| --- | --- |
| `accents` | `\'{e}` → é, `\"o` → ö, `\c c` → ç |
| `ligatures` | `\ae{}` → æ, `---` → —, LaTeX quotation marks |
| `cites` | `\cite[see]{key}` → [key], `\citep{key}` → (key) |
| `fancy` | `\dots` → …, `\_` → _, `\item` → ○ |
| `spacing` | Hide spacing commands and phantom arguments; `~` → space |
| `math_bounds` | Hide matched `$…$`, `$$…$$`, `\(…\)`, `\[…\]` markers |
| `math_delimiters` | Hide bracket sizing commands; `\langle` → ⟨ |
| `styles` | Hide supported formatting wrappers such as `\textbf{…}` |

The feature loads on demand, scans visible source lines, and caches decorations
between edits and viewport changes. Expensive Tree-sitter parses yield, keeping
source visible until ready. Buffer text, Tree-sitter colors, and window conceal
options are preserved. Comments, verbatim/code environments, inline verbatim,
macro definitions, paths, labels, and citation keys retain their source spelling.
Styles keep the original contents and colors; they do not emulate TeX fonts.
Accents support single ASCII letters with a precomposed Unicode equivalent.
Citation notes are hidden; keys remain visible. Greek letters, general math
symbols, fractions, scripts, section headings, and custom macro expansion are
outside these eight categories. Unrecognized constructs retain their source.

Requires the `latex` parser but does not start a Tree-sitter highlighter. Disable
VimTeX's conceal rules or legacy TeX syntax conceal when using this renderer to
avoid overlapping replacements. `conceal = false` (the default), or
`conceal = { enabled = false }`, disables it; missing parsers leave source visible.

## Context queries

All functions below return `boolean[, error]` and accept optional
`{ bufnr, pos = { row, byte_column } }`, with zero-based coordinates.
They are read-only and work without `setup()` or texlab.

| Function | Context |
| --- | --- |
| `in_math()` | Inline/display math or a math environment |
| `in_comment()` | LaTeX comments |
| `in_subscript()` / `in_superscript()` | Mathematical script payload |
| `in_numerator()` / `in_denominator()` | Nearest `\frac`, `\dfrac`, or `\tfrac` part |
| `in_table_cell()` | Supported table/alignment body cell |

Example LuaSnip condition:

```lua
local tex = require("tex-tools")
local in_power = function() return tex.in_superscript() end
-- s({ trig = "...", condition = in_power }, { ... })
```

See `:help tex-tools.txt` or [the reference](doc/tex-tools.txt) for commands,
`<Plug>` names, all Lua APIs, and context boundaries. Syntax follows the
installed parser; custom macro signatures are not inferred.

## Development

```sh
stylua --check lua tests
nvim --clean --headless -l tests/run.lua
```

Set `TEX_TOOLS_TEST_PARSER=/path/to/latex.so` if the parser is outside Neovim's
runtime path. Tests use the real parser, texlab client doubles, temporary
artifact directories, and a stdio LSP fixture. Running actual compiler binaries
requires your local toolchain.
