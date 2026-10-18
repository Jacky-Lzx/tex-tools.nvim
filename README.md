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

## Phase 2: Structural editing

- Command (`ac` / `ic`), argument (`aa` / `ia`), and formula (`a$` / `i$`) text objects.
- Surround the current line or selected lines with an environment, and unwrap an existing environment while keeping its body.
- Switch `$...$` ↔ `\(...\)` and `$$...$$` ↔ `\[...\]` without changing math mode or formula content.
- Rename commands, unwrap a single braced argument, and surround text with a command.
- Math bracket text objects, paired replacement/removal, and automatic sizing with `\left` / `\right`.
- List-item text objects (`ai` / `ii`), including multiline bodies and nested lists.

Command, argument, and formula objects follow the parser's structure and skip
comments and literal content. Command objects include only arguments owned by
the command node; selecting `\section{Title}` never includes its section body.

## Phase 3: List input

- Insert a sibling `\item` after the entire current item, including continuation paragraphs and nested lists.
- Support `itemize`, `enumerate`, and `description`, preserving the current item's indentation.
- Insert `\item[]` in a description list and enter Insert mode inside the empty label.
- Create the first item in an empty list and split inline item/end markers when needed.
- Optionally split a list item at the cursor with Enter, keeping the suffix in the new item.

Use `:TexToolsInsertItem` or `<localleader>li` in Normal or Insert mode. New items
are inserted at the current list level, with the cursor ready for typing.
Whitespace gaps use the preceding item. In a whitespace-only empty list, the
first item is added before the end marker, indented by one `shiftwidth` from
the begin line; `expandtab` and `tabstop` are respected.

Place the cursor in the list body. List markers, comments, literal content,
incomplete lists, and unsupported nearest environments cancel the operation.
Before the first item of a nonempty list, no item is selected. Existing item
labels and stars are not copied; surrounding text and comments are preserved.
One undo removes the new marker and the text typed immediately into it, while
preserving text previously typed in the old item.

Enable the optional Insert-mode Enter mapping with:

```lua
require("tex-tools").setup({ smart_enter = true })
```

At the end of a nonempty item, Enter creates a sibling. Inside its body, Enter
splits at the cursor, moving the suffix and following continuation lines into
the new item. Adjacent horizontal whitespace is trimmed; the original marker
keeps its separating space, and escaped spaces are preserved. Description
lists create an empty label and place
the cursor inside it. The current item's indentation is reused.

Empty items/lists, blank gaps after an item, comments, literal content, list
markers, and positions inside commands, arguments, or formulas use native
Enter. Unsupported or incomplete lists and a missing parser also fall back
silently. Native indentation and comment continuation apply on fallback.
One undo restores a split and removes immediately typed text, preserving
text typed before Enter. Use the explicit insert command to create the first
item in an empty list or insert after the entire item.

`smart_enter` defaults to `false`. Enabling it preserves existing Enter
mappings; `mappings = false` disables this default too. For a custom key in a
TeX buffer, use `<Plug>(TexToolsSmartEnter)` in Insert mode. For an existing
completion mapping, call `smart_enter()` in its fallback branch:

```lua
-- In after/ftplugin/tex.lua, or your own TeX FileType callback.
vim.keymap.set("i", "<CR>", function()
  if vim.fn.pumvisible() == 1 then
    return vim.keycode("<C-y>")
  end
  return require("tex-tools").smart_enter()
end, { buffer = true, expr = true, replace_keycodes = false })
```

## Phase 4: Structural navigation

- `]]` / `[[` jump to the next / previous section marker at any section level.
- `]i` / `[i` jump between item markers in the current list, skipping nested environments.
- `]e` / `[e` jump to environment begin markers throughout the buffer, including nested environments.
- `]m` / `[m` jump to inline/display formula openings and named math environments.
- Counts such as `3]]` and `2[i` skip multiple targets; `<C-o>` returns to the jump's origin.

These Normal-mode mappings land on the opening delimiter or command's
backslash and open folds containing the destination. Section navigation
recognizes `part`, `chapter`, `section`, `subsection`, `subsubsection`,
`paragraph`, and `subparagraph`,
including starred forms and the parser's `addpart` / `addchap` / `addsec` aliases.
Incomplete headers, comments, literal environments, and recognized definition
bodies are excluded. Valid headings remain reachable when their body has a
syntax error. Navigation follows the upstream syntax tree; macros are not
expanded, and legacy `\def` bodies are not identified as definition bodies.

List navigation stays in the nearest environment, which must be `itemize`,
`enumerate`, or `description` with matching begin/end markers. Items under
paragraph nodes are included; nested environments are skipped. Empty items,
labels, and starred markers are supported. From a list's begin/end marker or
a whitespace gap, the same position-based search applies. List navigation
is refused inside comments, literal content, and recognized definitions.

Environment navigation includes `document` and requires complete, matching
begin/end markers. Formula navigation includes `$...$`, `\(...\)`, `$$...$$`,
`\[...\]`, parser-recognized math environments, and configured
`math_environments`. Delimited formulas must be complete and have matching
delimiters. Nested formulas inside `\text{...}` are separate targets.
Both traverse in source order, skipping comments, literal/code environments
(including their markers), and recognized definition bodies. They can start
inside excluded content to reach a valid target elsewhere in the buffer.
`<localleader>lm` continues to jump between the current environment's markers.

All motions search strictly before/after the cursor. Moving backward from a
marker selects the preceding marker. Nested openings count as separate
targets in environment and formula navigation. Oversized counts stop at the furthest
available target without wrapping. If there is no target, the cursor and
jump history are preserved. All navigation works without texlab and in
unmodifiable buffers.

## Command editing

- `<localleader>lcr` / `:TexToolsRenameCommand [name]`: rename the innermost command, keeping all arguments, options, whitespace, and comments. For example, `\textbf{body}` becomes `\emph{body}`.
- `<localleader>lcd` / `:TexToolsUnwrapCommand`: remove a command with exactly one braced argument, keeping its contents. For example, `\textbf{body}` becomes `body`.
- `<localleader>lcs` in Visual mode: wrap the selected text with `\name{...}`. In Normal mode or with `:[range]TexToolsSurroundCommand [name]`, wrap the current line or Ex line range.

Omit a name to open an input prompt. Enter ASCII letters or `@`, optionally
followed by one `*`, without the leading backslash. A new name supplies its
own star: renaming `section*` to `chapter` removes the star. Control-symbol
commands such as `\%` are excluded. These are local edits to an invocation;
macro signatures, definitions, and uses elsewhere in the project are not
renamed or inferred.

Unwrap refuses optional or multiple arguments, non-group parameters, and
comments between the command and its argument. Comments inside the retained
body are preserved. Rename and unwrap refuse changes that would merge a bare
control word with adjacent letters. As with command text objects, a heading's
body is excluded from its invocation.

Visual surrounds support characterwise and linewise selections, forward and
backward, both `selection` settings, UTF-8, combining marks, and multiple
lines. The selected text is preserved without reindentation. Blockwise and
partial-character/virtual-space selections are refused. Surrounds require
nonempty text and reject selections crossing command, argument, formula, or
environment boundaries; complete structures or text within one body are
accepted. Any intersecting comments or literal content are refused.

All command edits require the real parser and a modifiable buffer. Commands
inside comments/literal content and incomplete invocations are refused.
Each operation can be undone with one `u`. Buffer edits while a name prompt
is open cancel the pending operation. Existing mappings are preserved;
`mappings = false` retains commands, Lua APIs, and `<Plug>` mappings.

## Math bracket editing

- `ad` / `id`: select the innermost math bracket pair including / excluding its markers.
- `<localleader>ldc` / `:TexToolsChangeMathDelimiters [shape]`: replace both brackets while keeping their size commands and all body text.
- `<localleader>ldd` / `:TexToolsUnwrapMathDelimiters`: remove both markers, preserving their contents.
- `<localleader>ldt` / `:TexToolsToggleMathDelimiterSize`: switch `(x)` ↔ `\left(x\right)`, likewise for the other supported pairs.

Shapes are `paren`, `bracket`, `brace`, `angle`, `vert`, and `Vert`, producing
`()`, `[]`, `\{\}`, `\langle\rangle`, `\lvert\rvert`, and `\lVert\rVert`.
Aliases are `(`, `[`, `{`, `<`, `|`, and `\|`, respectively. Omit the shape to
prompt. For example, changing `\left(x\right)` to `bracket` produces
`\left[x\right]`. A separator space is added when a new control-word
delimiter would otherwise consume adjacent letters.

Plain brackets are matched from Tree-sitter tokens within one syntax scope;
commands and argument groups remain intact. Parser-owned optional group
markers and unowned square brackets directly following a command are excluded,
since their role may depend on an unknown macro signature. Sized pairs use the
parser's `math_delimiter` fields. All operations require math context and skip
comments, literal content, text-mode content, and parser-owned environment headers. Nested
inline math inside text-mode content remains supported. Body comments,
whitespace, newlines, and UTF-8 text are preserved. Each edit is one undo step.

Explicit `\left` / `\right` pairs may have mixed brackets, invisible `.`, or
symmetric bars. They support selection, replacement, and removal, but size
toggling requires matching visible directional delimiters. Plain `|...|` is
ambiguous and is excluded; use `\lvert...\rvert` instead. Fixed sizes such as
`\bigl` / `\bigr` and custom delimiter macros are outside this first version.

Removing `\left` / `\right` is refused when it would orphan a `\middle` at
that level. Unwrapping also refuses token merging or comments inside a marker
that would be discarded. Enabling automatic sizing cannot span alignment cells
or rows. These commands are separate from `<localleader>lf`, which changes the spelling of
the enclosing inline/display formula delimiters.

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
    smart_enter = false, -- Optional list Enter mapping; preserves existing mappings.
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

Structural edits use `<localleader>l` with `c` for commands, `e` for
environments, and `d` for math brackets. Within those groups, `r` renames,
`c` changes a bracket pair, `d` removes the wrapper, `s` surrounds text, and
`t` toggles a property. `<localleader>lc` and `<localleader>le` are group
prefixes; surrounding now uses `<localleader>lcs` and `<localleader>les`.
The former unprefixed edit keys are no longer installed by default.
Ex commands, `<Plug>` names, and Lua APIs retain their names.
Set `vim.g.maplocalleader` before loading the plugin to choose the prefix key.

- `<localleader>ler` → `:TexToolsRenameEnvironment [name]`; prompts when the name is omitted.
- `<localleader>lcr` → `:TexToolsRenameCommand [name]`; renames the innermost command.
- `<localleader>lcd` → `:TexToolsUnwrapCommand`; keeps the contents of one braced argument.
- `<localleader>ldc` / `<localleader>ldd` / `<localleader>ldt` → change / unwrap / toggle the size of math brackets; see [Math bracket editing](#math-bracket-editing).
- `<localleader>lcs` (Normal / Visual) → `:TexToolsSurroundCommand [name]`; wraps a line or exact Visual selection, prompting for the name.
- `<localleader>let` → `:TexToolsToggleEnvironmentStar`, e.g. `equation` ↔ `equation*`.
- `<localleader>lm` → `:TexToolsJumpEnvironment`; jumps from the body or begin marker to end, and from end back to begin.
- `<localleader>ll` → `:TexToolsBuild`; saves the current file, then requests a texlab build.
- `<localleader>lv` → `:TexToolsForwardSearch`; asks texlab to locate the current cursor position in the PDF.
- `ae` / `ie` → selects the whole environment / its body, e.g. `vae`, `yie`, `dae`.
- `ac` / `ic` → selects the command call / command name, e.g. `dac`, `yic`. The inner name excludes the backslash and includes a trailing star.
- `aa` / `ia` → selects the innermost brace or bracket group / its contents, e.g. `yaa`, `cia`.
- `a$` / `i$` → selects the formula including / excluding its delimiters, e.g. `da$`, `yi$`. Named math environments and configured custom math environments are included.
- `ad` / `id` → selects math brackets including / excluding their markers, e.g. `yad`, `cid`.
- `ai` / `ii` → selects the current list item including its marker / just its body, e.g. `dai`, `cii`.
- `<localleader>les` → `:[range]TexToolsSurroundEnvironment [name]`; wraps the current line in Normal mode or selected lines in Visual mode, prompting for a name.
- `<localleader>led` → `:TexToolsUnwrapEnvironment`; removes both markers and begin options while preserving the body.
- `<localleader>lf` → `:TexToolsToggleMathDelimiters`; switches between dollar and backslash delimiters, preserving inline/display mode.
- `<localleader>li` (Normal / Insert) → `:TexToolsInsertItem`; inserts a sibling item and enters Insert mode in its body or description label.
- `<CR>` (Insert, only with `smart_enter = true`) → `<Plug>(TexToolsSmartEnter)`; splits at the cursor or uses native Enter.
- `]]` / `[[` (Normal) → `:TexToolsNextSection` / `:TexToolsPreviousSection`.
- `]i` / `[i` (Normal) → `:TexToolsNextItem` / `:TexToolsPreviousItem`.
- `]e` / `[e` (Normal) → `:TexToolsNextEnvironment` / `:TexToolsPreviousEnvironment`.
- `]m` / `[m` (Normal) → `:TexToolsNextMath` / `:TexToolsPreviousMath`.

Navigation commands accept a count prefix too, for example
`:3TexToolsNextSection`, `:2TexToolsPreviousItem`, or `:2TexToolsNextMath`.
Lua callers can use `jump_environment_start(direction, count)` and
`jump_math(direction, count)`, with direction `1` (next) or `-1` (previous)
and an optional positive count. `jump_environment()` retains its begin/end jump.

`ie` excludes the begin marker's optional arguments. When markers occupy their
own lines, it also excludes the newlines surrounding the body. An empty body
cancels the operation. `ae` includes the `document` environment.

`ai` includes the current `\item` or `\item*`, its optional label, and its
body in `itemize`, `enumerate`, and `description`. `ii` selects only the body,
excluding surrounding whitespace: `cii` preserves the marker and label.
Escaped spaces at the end of the body remain part of the selection.
Bodies include continuation paragraphs and nested lists. Default selection
stays at the nearest list level; `2ai` / `2ii` select the enclosing parent item.
The nearest environment must be a supported list, and the cursor must be in
its body. A marker or label selects its item; whitespace between items uses
the preceding item, and indentation before a marker selects that marker's item.

When an item occupies whole lines, `ai` selects linewise, including its
indentation, final newline, and any trailing comment on the final line.
Following blank lines and standalone comments remain. Inline items select
characterwise and include following horizontal whitespace. `ii` remains
characterwise and excludes a trailing comment outside the parser's item node;
comments inside the body remain part of it. Empty bodies cancel `ii` but
remain selectable with `ai`. Comments, parser-recognized literal content,
definitions, and incomplete lists are refused. Syntax follows the installed
parser; if it marks an unfinished description label such as `\item[]` as an
error, finish the label before selecting items in that list.

All six text-object kinds support counts in Visual and operator-pending mode.
A count selects the requested enclosing object of the same kind at the cursor:
`1` selects the innermost, `2` the next enclosing object, and so on.
For example, `v2ae` selects the second enclosing environment, `d2ac` deletes
the second enclosing command call, `y2ia` yanks the second enclosing argument's
contents, and `v2a$` / `v2ad` select the second enclosing formula / math bracket.
Operator and text-object counts multiply: `2d2ac` selects depth four.

Counts never advance to sibling structures. Curly and optional groups share
argument depth; inline/display formulas and named math environments share
formula depth. Math bracket counts include plain and left/right-sized pairs
and stay inside the nearest formula or math environment. Empty inner objects
still occupy a level; only the requested object's inner part must be nonempty.
If the depth is unavailable or the target is invalid, cancel the whole
operation without changing text or registers. Failed default/Plug mappings
also preserve undo history and the preceding native repeat. Successful
operators retain native dot repeat and undo behavior.

Star toggling changes the name only; the document class and packages determine
whether the resulting environment exists.

Environment surrounding operates on whole lines, including when a characterwise or blockwise
Visual selection is used. Markers use the first selected line's indentation;
the body is preserved without reindentation. For example, `:2,5TexToolsSurroundEnvironment quote`
wraps lines 2 through 5. Unwrapping removes standalone marker lines entirely,
preserves blank body lines and comments, and handles inline markers. Each wrap,
unwrap, and delimiter switch can be undone with one `u`.

Formula delimiter switching leaves named environments such as `equation`
to the environment commands. Incomplete or mismatched formula delimiters are
rejected. Arguments and optional groups must be recognized by the parser;
the plugin does not infer custom macro signatures or parse unrecognized
optional arguments.

You can also define your own `<Plug>` mappings:

```lua
vim.keymap.set("n", "<leader>te", "<Plug>(TexToolsRenameEnvironment)")
vim.keymap.set({ "x", "o" }, "aE", "<Plug>(TexToolsAroundEnvironment)")
vim.keymap.set({ "n", "i" }, "<C-j>", "<Plug>(TexToolsInsertItem)")
vim.keymap.set("n", "]s", "<Plug>(TexToolsNextSection)")
vim.keymap.set("x", "<leader>tc", "<Plug>(TexToolsSurroundCommand)")
```

See [doc/tex-tools.txt](doc/tex-tools.txt) for all `<Plug>` names and API details.
You can migrate VimTeX workflows gradually. When using both plugins, consider
disabling one plugin's mappings to avoid conflicts.

## Repeating structural edits

After a successful structural edit, move to another target and press `.`.
For example, use `<localleader>lcr` to rename `\textbf{first}` to
`\emph{first}`, then move inside another command and press `.` to rename
it to `\emph` without another prompt.

Repeat supports command/environment renaming and unwrapping, environment
star toggling, math bracket replacement/removal and size toggling, and
formula delimiter switching. Names and shapes reuse the accepted value;
toggles act on the new target's current state. Each repeat queries the
syntax tree again, including in another `tex` / `plaintex` buffer. It never
reuses an old selection or byte range. Comments, literal content, invalid
targets, missing parsers, and unmodifiable buffers are refused.

Each `.` is one undo step. A count such as `3.` applies the operation three
times at the same cursor, useful for unwrapping nested commands; it does not
advance to sibling structures. A counted repeat stops at the first invalid
target, and its successful edits can be undone together.

Recording uses native `g@` / `operatorfunc`, with no extra dependency or mapping
on `.`. A subsequent native edit or another native operator supplies its own
repeat. Existing user mappings on `.` take precedence. Failed, cancelled,
stale, and unchanged operations leave the preceding repeat intact.

Normal-mode mappings, Ex commands, and Lua editing APIs record completed edits
when the target is the current `tex` / `plaintex` buffer in Normal mode.
An accepted prompt records its resolved value only after the edit succeeds.
A prompt that edits a now-hidden buffer still edits that buffer, but leaves
the current buffer's repeat intact. API calls during Insert mode preserve
native typing behavior. Range surrounds, list insertion, and smart Enter do
not register a structural repeat; text-object operators keep native repeats.

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
tex.rename_command("emph")
tex.unwrap_command()
tex.surround_command("textbf") -- current line
tex.surround_command("emph", { range = { 0, 7, 0, 11 } }) -- zero-based bytes, end-exclusive
tex.surround_command_visual("emph") -- active characterwise/linewise Visual selection
tex.rename_environment("align*")
tex.toggle_environment_star()
tex.jump_environment()
tex.surround_environment("quote") -- current line
tex.surround_environment("quote", { line1 = 2, line2 = 5 }) -- one-based, inclusive
tex.unwrap_environment()
tex.toggle_math_delimiters()
tex.change_math_delimiters("bracket") -- (x) -> [x], keeping any sizing commands
tex.unwrap_math_delimiters() -- remove brackets, preserve contents
tex.toggle_math_delimiter_size() -- (x) <-> \left(x\right)
tex.insert_item() -- insert a sibling list item and enter Insert mode
tex.smart_enter() -- encoded keys for an Insert-mode expression mapping
tex.jump_section(1, 3) -- next section marker, repeated three times
tex.jump_item(-1) -- preceding item marker at the current list level
tex.build()
tex.forward_search()

-- Query a specific buffer and position; rows and byte columns are zero-based.
tex.in_math({ bufnr = 3, pos = { 9, 4 } })

-- kind: "environment", "command", "argument", "math", "delimiter", or "item"; true selects the inner part.
tex.textobject_range("argument", true) -- {start_row, start_byte, end_row, end_byte}, end-exclusive
tex.select_textobject("argument", true) -- enter a characterwise Visual selection
tex.textobject_range("command", false, { count = 2 }) -- second enclosing command call
tex.select_textobject("environment", false, 2) -- select the second enclosing environment
tex.textobject_range("item", true) -- current item body, preserving its marker and label
```

Context queries do not display notifications and can be called frequently.
They return `false, error` when the parser is unavailable. `environment()` returns
`nil, error` when no usable environment is found. Editing operations return
`true` or `false, error`; for an asynchronous rename, `true` means the input
prompt has opened. Build and forward search return `true, request_id` when the
request is sent, then report the result through a notification.

`surround_environment()` prompts when the name is omitted and defaults to the
current line when no range is given. A buffer change while the prompt is open
cancels the pending edit. `textobject_range()` returns a range or `nil, error`
without notifying, and accepts optional `{ bufnr, pos, count }` query options.
`count` defaults to `1` and must be a positive integer. `select_textobject()`
selects in the current buffer, accepts an optional third `count` argument, and
returns `true` or `false, error`. Lua APIs default to depth one independently
of pending key counts. Custom mappings can pass `vim.v.count1` explicitly.
Selections are characterwise except for `ai` on whole-line items, which uses
linewise Visual mode to include the final newline.
For operator mappings, use the provided `<Plug>` entries to preserve undo
and repeat state when no matching object exists.

`insert_item()` returns `true` after inserting and entering Insert mode, or
`false, error` without modifying the buffer or moving the cursor. Like the
other editing APIs, it reports errors to its caller; commands and mappings
display those errors as notifications.

`smart_enter()` returns encoded keystrokes for an Insert-mode expression mapping
with `replace_keycodes = false`. It does not edit or query the buffer during
expression evaluation. The returned action checks the syntax when executed,
then splits the item or queues native Enter without remapping or notifications.
It works without `setup()`; only automatic mapping installation requires setup.

`jump_section(direction, count)` and `jump_item(direction, count)` use `1` for
next and `-1` for previous. `count` defaults to `1` and must be a positive
integer. They return `true` on movement or `false, error` without moving.
They do not notify or require `setup()`; commands and mappings display errors.
Custom Normal-mode Lua mappings can pass `vim.v.count1` to retain count support.

`change_math_delimiters(shape)`, `unwrap_math_delimiters()`, and
`toggle_math_delimiter_size()` return `true` or `false, error` without notifying
and work without `setup()`. Omitting the shape prompts; `true` then means the
prompt opened. The pending edit targets the original buffer and is cancelled
if that buffer changes. `textobject_range("delimiter", inner, opts)` accepts
the same `{ bufnr, pos, count }` options as the other text objects.

`rename_command(name)` and `surround_command(name, opts)` prompt when `name`
is omitted. `surround_command()` accepts either a byte `range` or one-based
inclusive `line1`/`line2`, defaulting to the current line. It copies the range
before opening a prompt. `surround_command_visual(name)` reads the active
Visual selection and leaves Visual mode before prompting or editing.
Together with `unwrap_command()`, these APIs return `true` or `false, error`
without notifying; `true` for a prompt means it has opened. They work without
`setup()` and edit the original buffer even if a different buffer is current
when the prompt finishes, provided the original buffer is unchanged.

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
2. **Implemented: Editing** — Counted environment, command, argument, formula, math bracket, and list-item text objects; command renaming and surrounds; adding and removing surrounding environments; formula delimiter switching and math bracket editing/sizing; native dot repeat for cursor-based structural edits.
3. **In progress: Input** — Explicit `\item` insertion and optional context-aware Enter are implemented. Further input helpers should compose with existing snippet and pairs plugins.
4. **Implemented: Navigation** — Section, same-level list-item, environment, and formula jumps with counts, jump history, and fold opening.

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

Tests cover context boundaries, environment editing, line and Visual surrounds,
math delimiter round trips, undo, UTF-8 text objects, actual operator mappings,
stale asynchronous prompts, nested list insertion, Normal/Insert-mode typing,
description labels, indentation, smart Enter splits/fallbacks, rapid repeated
Enter input, section/list-item/environment/formula navigation, counted mappings, jump history,
fold opening, command renaming/unwrapping, exact Visual command surrounds,
math bracket matching, paired edits, automatic sizing, alignment and middle guards,
syntax-boundary guards, counted enclosing text objects, list-item bodies and
labels, nested list selection, native and counted dot
repeat, native editing compatibility, and texlab request parameter encoding. texlab tests
use a client double and do not start a LaTeX compiler or PDF viewer. Verify
actual builds and PDF navigation with your configured local toolchain.

References: [VimTeX documentation](https://github.com/lervag/vimtex/blob/master/doc/vimtex.txt),
[Tree-sitter LaTeX node definitions](https://github.com/latex-lsp/tree-sitter-latex/blob/master/src/node-types.json),
and [texlab protocol extensions](https://github.com/latex-lsp/texlab/wiki/Protocol-Extensions).
