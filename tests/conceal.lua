return function(h)
  local test, eq, buffer = h.test, h.eq, h.buffer
  local tex = require('tex-tools')
  local prepared = false

  local function screen(row, win)
    win = win or vim.api.nvim_get_current_win()
    vim.cmd.redraw({ bang = true })
    local origin = vim.fn.win_screenpos(win)
    local result = {}
    for col = origin[2], origin[2] + vim.api.nvim_win_get_width(win) - 1 do
      result[#result + 1] = vim.fn.screenstring(origin[1] + row - 1, col)
    end
    return table.concat(result):gsub('%s+$', '')
  end

  local function fixture(source, options)
    local bufnr = buffer(source)
    vim.cmd.syntax('off')
    vim.wo.number, vim.wo.relativenumber = false, false
    vim.wo.signcolumn, vim.wo.foldcolumn, vim.wo.statuscolumn = 'no', '0', ''
    vim.wo.wrap, vim.wo.foldenable = false, false
    vim.wo.conceallevel, vim.wo.concealcursor = 2, 'nc'
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    tex.setup({ conceal = options == nil and true or options })
    -- Rendering assertions use a ready tree; async completion has its own test.
    vim.treesitter.get_parser(bufnr, 'latex'):parse()
    return bufnr
  end

  local function check(name, fn)
    test('conceal: ' .. name, function()
      if not prepared then
        -- Earlier suites retain hundreds of modified fixtures. Their assertions
        -- are complete; release them before testing setup on existing buffers.
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if bufnr ~= vim.api.nvim_get_current_buf() then
            vim.api.nvim_buf_delete(bufnr, { force = true })
          end
        end
        prepared = true
      end
      local ok, err = xpcall(fn, debug.traceback)
      tex.setup()
      vim.wo.conceallevel, vim.wo.concealcursor = 0, ''
      if not ok then
        error(err)
      end
    end)
  end

  check('disabled feature stays unloaded', function()
    eq(nil, package.loaded['tex-tools.conceal'])
    fixture('--- \\ae{}', false)
    eq('--- \\ae{}', screen(1))
    eq(nil, package.loaded['tex-tools.conceal'])
  end)

  for _, case in ipairs({
    { 'accents', [=[\'{e} \"o \c c \v{S} \H{o}]=], 'é ö ç Š ő' },
    {
      'ligatures',
      [=[\ae{} \OE{} \ss{} --- -- ``hi'' !` ?` ,, \dj{}\DJ{}\lq{}\rq{}]=],
      'æ Œ ß — – “hi” ¡ ¿ „ đĐ‘’',
    },
    { 'cites', [=[\cite[see][p.2]{a--b,c} \citep{k} \parencite{k}]=], '[a--b,c] (k) (k)' },
    { 'fancy', [=[\dots \ldots \colon \slash \_ \item[Label] body]=], '… … : / _ ○[Label] body' },
    { 'spacing', [=[a\,b\;c\!d~e\ f\quad g\hspace{1em}h\phantom{hidden}i]=], 'abcd e f ghi' },
    { 'math_bounds', [=[$x$ \(y\) $$z$$ \[w\]]=], 'x y z w' },
    { 'math_delimiters', [=[$\left\langle x \middle| y \right\rangle$]=], '⟨ x | y ⟩' },
    { 'sized and invisible delimiters', [=[$\bigl(a\bigr) + \left.x\right| + \{z\}$]=], '(a) + x| + {z}' },
    { 'styles', [=[\textbf{bold \emph{nested}} $\mathrm{abc}$]=], 'bold nested abc' },
    { 'UTF-8 byte columns', [=[é --- \textit{ö \ae{}}]=], 'é — ö æ' },
    { 'scripts and fractions stay intact', [=[$x_i^2 -- \alpha + \frac{a}{b}$]=], 'x_i^2 -- α + \\frac{a}{b}' },
    { 'math symbols', [=[$\alpha \Gamma \times \leq \infty \to \sum_i$]=], 'α Γ × ≤ ∞ → ∑_i' },
    { 'nested text in math', [=[$x + \text{``words'' ---} + y$]=], 'x + “words” — + y' },
  }) do
    check(case[1] .. ' renders without changing source', function()
      local bufnr = fixture(case[2])
      eq(case[3], screen(1))
      eq(case[2], h.content())
      eq(nil, vim.treesitter.highlighter.active[bufnr])
      eq({}, vim.api.nvim_buf_get_extmarks(bufnr, vim.api.nvim_create_namespace('tex-tools.conceal'), 0, -1, {}))
    end)
  end

  for _, source in ipairs({
    [=[% \ae{} --- $x$ \textbf{source}]=],
    [=[\begin{verbatim}\ae ---\end{verbatim}]=],
    [=[\begin{lstlisting}\ae ---\end{lstlisting}]=],
    [=[\begin{minted}{lua}\ae ---\end{minted}]=],
    [=[\newcommand{\example}{\textbf{source} ---}]=],
    [=[\def\example{\ae ---}]=],
    [=[\def\example#1#2{\ae ---}]=],
    [=[\verb|\ae ---|]=],
    [=[\verb*+\ae ---+]=],
    [=[\lstinline[language=TeX]|\ae ---|]=],
    [=[\mintinline{tex}{\ae ---}]=],
    [=[\url{https://a--b/x_1}]=],
    [=[\label{a--b} \ref{a--b}]=],
    [=[\includegraphics[width=1--2]{a--b.pdf}]=],
    [=[\textbf{unfinished ---]=],
    [=[$unfinished]=],
    [=[\'{ab} \unknown{source}]=],
  }) do
    check('protected source ' .. source, function()
      fixture(source)
      eq(source, screen(1))
    end)
  end

  check('categories and enabled flag can be reconfigured', function()
    fixture([=[--- \ae{} $x$ \textbf{b}]=], { ligatures = false, styles = false })
    eq([=[--- \ae{} x \textbf{b}]=], screen(1))
    tex.setup({ conceal = true })
    eq('— æ x b', screen(1))
    tex.setup({ conceal = { enabled = false } })
    eq([=[--- \ae{} $x$ \textbf{b}]=], screen(1))
  end)

  check('individual categories can be disabled', function()
    for name, source in pairs({
      accents = [=[\'{e}]=],
      ligatures = '---',
      cites = [=[\cite{k}]=],
      fancy = [=[\dots]=],
      spacing = [=[\quad]=],
      math_bounds = '$x$',
      math_symbols = [=[$\alpha$]=],
      math_delimiters = [=[$\left(x\right)$]=],
      styles = [=[\textbf{b}]=],
    }) do
      local options = { [name] = false }
      if name == 'math_delimiters' or name == 'math_symbols' then
        options.math_bounds = false
      end
      fixture(source, options)
      eq(source, screen(1))
    end
  end)

  check('edits invalidate cached decorations', function()
    fixture('before ---')
    eq('before —', screen(1))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after \\ae{}' })
    eq('after æ', screen(1))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '% after ---' })
    eq('% after ---', screen(1))
  end)

  check('native window options and cursor line behavior', function()
    fixture('--- \\ae{}\n--- \\ae{}')
    eq('— æ', screen(1))
    vim.wo.concealcursor = ''
    eq('--- \\ae{}', screen(1))
    eq('— æ', screen(2))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq('— æ', screen(1))
    eq('--- \\ae{}', screen(2))
    vim.wo.conceallevel = 0
    eq('--- \\ae{}', screen(1))
  end)

  check('multiple windows have independent options', function()
    fixture('--- \\ae{}')
    local first = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    local second = vim.api.nvim_get_current_win()
    local ok, err = pcall(function()
      vim.wo[second].conceallevel = 0
      eq('— æ', screen(1, first))
      eq('--- \\ae{}', screen(1, second))
    end)
    vim.api.nvim_win_close(second, true)
    if not ok then
      error(err)
    end
  end)

  check('multiline wrappers with opening above viewport', function()
    local source = { '\\textbf{' }
    for _ = 1, 100 do
      source[#source + 1] = 'body'
    end
    source[#source + 1] = 'last}'
    fixture(table.concat(source, '\n'))
    vim.api.nvim_win_set_cursor(0, { #source, 0 })
    vim.cmd('normal! zt')
    eq('last', screen(1))
  end)

  check('missing parser falls back to source', function()
    fixture('--- \\ae{}')
    local get_parser = vim.treesitter.get_parser
    vim.treesitter.get_parser = function()
      error('parser unavailable')
    end
    local ok, err = pcall(function()
      eq('--- \\ae{}', screen(1))
    end)
    vim.treesitter.get_parser = get_parser
    if not ok then
      error(err)
    end
  end)

  check('large buffers scan only visible lines and reuse cached results', function()
    fixture(table.concat(vim.fn['repeat']({ 'text --- \\ae{} $x$' }, 10000), '\n'))
    local get_lines, get_parser = vim.api.nvim_buf_get_lines, vim.treesitter.get_parser
    local scanned, parses = 0, 0
    vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
      scanned = scanned + last - first
      return get_lines(buf, first, last, strict)
    end
    vim.treesitter.get_parser = function(...)
      parses = parses + 1
      return get_parser(...)
    end
    local ok, err = pcall(function()
      eq('text — æ x', screen(1))
      eq(true, scanned <= vim.api.nvim_win_get_height(0) + 2)
      eq(1, parses)
      local initial = scanned
      eq('text — æ x', screen(1))
      eq(initial, scanned)
      eq(1, parses)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      eq('text — æ x', screen(1))
      eq(1, parses)
    end)
    vim.api.nvim_buf_get_lines, vim.treesitter.get_parser = get_lines, get_parser
    if not ok then
      error(err)
    end
  end)

  check('pending async parse preserves source and redraws after completion', function()
    local bufnr = fixture('--- \\ae{}')
    local parser = vim.treesitter.get_parser(bufnr, 'latex')
    local trees = parser:parse()
    local get_parser, callback, requests = vim.treesitter.get_parser, nil, 0
    vim.treesitter.get_parser = function()
      return {
        parse = function(_, _, on_parse)
          requests = requests + 1
          callback = on_parse
        end,
      }
    end
    local ok, err = pcall(function()
      eq('--- \\ae{}', screen(1))
      eq('--- \\ae{}', screen(1))
      eq(1, requests)
      vim.treesitter.get_parser = get_parser
      callback(nil, trees)
      eq(
        true,
        vim.wait(1000, function()
          return vim.fn.screenstring(1, 1) == '—'
        end)
      )
      eq('— æ', screen(1))
    end)
    vim.treesitter.get_parser = get_parser
    if not ok then
      error(err)
    end
  end)

  check('symbol overrides, disabling and reconfiguration keep their source', function()
    local source = [=[$\alpha \beta \RR \unknown$]=]
    fixture(source, { symbols = { alpha = 'Α', beta = false, RR = 'ℝ' } })
    eq([=[Α \beta ℝ \unknown]=], screen(1))
    eq(source, h.content())
    tex.setup({ conceal = { math_symbols = false, symbols = { RR = 'ℝ' } } })
    eq([=[\alpha \beta \RR \unknown]=], screen(1))
    tex.setup({ conceal = true })
    eq([=[α β \RR \unknown]=], screen(1))
  end)

  check('symbols require math context and exact control words', function()
    fixture([=[\alpha $\alpha + \alphabet + \text{\beta $\gamma$}$]=])
    eq([=[\alpha α + \alphabet + \beta γ]=], screen(1))
    fixture('\\begin{align}\n\\alpha & = \\beta\n\\end{align}')
    eq('α & = β', screen(2))
  end)

  check('symbols protect comments, definitions, paths, citations and inline verbatim', function()
    for _, source in ipairs({
      [=[% $\alpha$]=],
      [=[\newcommand{\foo}{$\alpha$}]=],
      [=[\def\foo{$\alpha$}]=],
      [=[\verb|$\alpha$|]=],
      [=[\begin{verbatim}$\alpha$\end{verbatim}]=],
      [=[\url{\alpha}]=],
      [=[\label{\alpha}]=],
    }) do
      fixture(source)
      eq(source, screen(1))
    end
  end)

  check('symbol mappings reject malformed names and glyphs', function()
    for _, symbols in ipairs({
      { ['\\alpha'] = 'α' },
      { ['frac{x}'] = '½' },
      { [1] = 'α' },
      { alpha = '' },
      { alpha = 'ab' },
      { alpha = true },
      { alpha = '\n' },
      { alpha = {} },
    }) do
      eq(false, pcall(tex.setup, { conceal = { symbols = symbols } }))
    end
    eq(false, pcall(tex.setup, { conceal = { symbols = false } }))
    eq(false, pcall(tex.setup, { conceal = { math_symbols = 1 } }))
  end)

  check('configuration rejects unknown or nonboolean categories', function()
    eq(false, pcall(tex.setup, { conceal = { accents = 1 } }))
    eq(false, pcall(tex.setup, { conceal = { greek = true } }))
    eq(false, pcall(tex.setup, { conceal = 'yes' }))
  end)
end
