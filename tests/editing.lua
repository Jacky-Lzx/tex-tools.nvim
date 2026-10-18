return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function selected(kind, inner)
    local range, err = tex.textobject_range(kind, inner)
    assert(range, err)
    local sr, sc, er, ec = unpack(range)
    return table.concat(vim.api.nvim_buf_get_text(0, sr, sc, er, ec, {}), '\n')
  end

  test('command objects select the innermost call or its name', function()
    buffer('before \\textbf{bold \\emph{中文}} after')
    at('中文')
    eq('\\emph{中文}', selected('command', false))
    eq('emph', selected('command', true))
    at('bold')
    eq('\\textbf{bold \\emph{中文}}', selected('command', false))
  end)

  test('command objects include multiple arguments and starred names', function()
    buffer('\\mycmd*{one}{two}')
    at('two')
    eq('\\mycmd*{one}{two}', selected('command', false))
    eq('mycmd*', selected('command', true))
  end)

  test('specialized command objects include options and stop before the body', function()
    buffer('\\section[Short]{Title}\nBody text\n{standalone group}')
    at('Title')
    eq('\\section[Short]{Title}', selected('command', false))
    at('Body')
    eq(nil, tex.textobject_range('command', false))
    at('standalone')
    eq(nil, tex.textobject_range('command', false))
  end)

  test('command object works for commands without arguments', function()
    buffer('before \\LaTeX after')
    at('LaTeX')
    eq('\\LaTeX', selected('command', false))
    eq('LaTeX', selected('command', true))
  end)

  test('argument objects select nested curly and optional groups', function()
    buffer('\\section[Short]{Title \\emph{中文}}')
    at('中文')
    eq('{中文}', selected('argument', false))
    eq('中文', selected('argument', true))
    at('Title')
    eq('Title \\emph{中文}', selected('argument', true))
    at('Short')
    eq('[Short]', selected('argument', false))
    eq('Short', selected('argument', true))
  end)

  test('argument objects preserve multiline content and escaped braces', function()
    buffer('\\textbf{first\n中文 \\{ literal \\}}')
    at('first')
    eq('first\n中文 \\{ literal \\}', selected('argument', true))
  end)

  test('empty arguments cancel inner operators but allow around objects', function()
    buffer('\\textbf{}')
    at('{}')
    eq(nil, tex.textobject_range('argument', true))
    eq('{}', selected('argument', false))
    keys('dia')
    eq('\\textbf{}', content())
  end)

  test('incomplete command and argument objects cancel operators', function()
    buffer('\\textbf{unfinished')
    at('unfinished')
    local original = content()
    eq(nil, tex.textobject_range('command', false))
    eq(nil, tex.textobject_range('argument', false))
    keys('dac')
    eq(original, content())
  end)

  for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    test('command and argument operators with selection=' .. selection, function()
      vim.o.selection = selection
      buffer('before \\textbf{中文} after')
      at('中文')
      keys('yia')
      eq('中文', vim.fn.getreg('"'))
      keys('yic')
      eq('textbf', vim.fn.getreg('"'))
      keys('dac')
      eq('before  after', content())
      vim.o.selection = 'inclusive'
    end)
  end

  for _, expression in ipairs({ '$中文+x$', '\\(中文+x\\)', '$$中文+x$$', '\\[中文+x\\]' }) do
    test('formula objects and operators: ' .. expression, function()
      buffer('before ' .. expression .. ' after')
      at('中文')
      eq(expression, selected('math', false))
      eq('中文+x', selected('math', true))
      keys('yi$')
      eq('中文+x', vim.fn.getreg('"'))
      keys('da$')
      eq('before  after', content())
    end)
  end

  test('formula object selects the nested formula inside text mode', function()
    buffer('\\[x + \\text{words $y$}\\]')
    at('$y$', 1)
    eq('$y$', selected('math', false))
    at('words')
    eq('\\[x + \\text{words $y$}\\]', selected('math', false))
  end)

  test('named math environments have formula objects', function()
    buffer('\\begin{align*}\n  x &= y\n\\end{align*}')
    at('x &=')
    eq('  x &= y', selected('math', true))
    eq(content(), selected('math', false))
    local original = content()
    eq(false, tex.toggle_math_delimiters())
    eq(original, content())
  end)

  test('custom math environment objects use the enclosing math environment', function()
    tex.setup({ math_environments = { 'mymath' } })
    buffer('\\begin{mymath}\n\\begin{group}\nx\n\\end{group}\n\\end{mymath}')
    at('x')
    eq(content(), selected('math', false))
    eq('\\begin{group}\nx\n\\end{group}', selected('math', true))
    tex.setup()
  end)

  test('empty formulas and math environments have no inner object', function()
    buffer('\\(\\)')
    at('\\(')
    eq(nil, tex.textobject_range('math', true))
    eq('\\(\\)', selected('math', false))
    buffer('\\begin{equation}\n\\end{equation}')
    at('equation')
    eq(nil, tex.textobject_range('math', true))
  end)

  for _, fixture in ipairs({
    '\\[x$$',
    '\\(x$',
    '$unfinished',
    '\\[unfinished',
  }) do
    test('refuse malformed math delimiters: ' .. fixture, function()
      buffer(fixture)
      at(fixture:find('unfinished', 1, true) and 'unfinished' or 'x')
      eq(nil, tex.textobject_range('math', false))
      eq(false, tex.toggle_math_delimiters())
      eq(fixture, content())
    end)
  end

  for _, fixture in ipairs({
    '% \\textbf{ignored $x$}',
    '\\[\nx % \\textbf{ignored $y$}\n\\]',
    '\\begin{verbatim}\n\\textbf{ignored $x$}\n\\end{verbatim}',
    '\\begin{minted}{latex}\n\\textbf{ignored $x$}\n\\end{minted}',
  }) do
    test('structure edits ignore comments and literal content: ' .. fixture:match('[^\n]+'), function()
      buffer(fixture)
      at('ignored')
      for _, kind in ipairs({ 'command', 'argument', 'math' }) do
        eq(nil, tex.textobject_range(kind, false))
      end
      eq(false, tex.toggle_math_delimiters())
      eq(fixture, content())
    end)
  end

  for _, pair in ipairs({
    { '$中文+x$', '\\(中文+x\\)' },
    { '$$中文+x$$', '\\[中文+x\\]' },
    { '\\[\nx + y\n\\]', '$$\nx + y\n$$' },
  }) do
    test('math delimiter round trip: ' .. pair[1], function()
      buffer('prefix ' .. pair[1] .. ' suffix')
      at(pair[1]:find('中文', 1, true) and '中文' or 'x + y')
      eq(true, tex.toggle_math_delimiters())
      eq('prefix ' .. pair[2] .. ' suffix', content())
      at(pair[1]:find('中文', 1, true) and '中文' or 'x + y')
      eq(true, tex.toggle_math_delimiters())
      eq('prefix ' .. pair[1] .. ' suffix', content())
    end)
  end

  test('math delimiter switching is one undo operation', function()
    buffer('before $中文$ after')
    at('中文')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.toggle_math_delimiters())
    vim.cmd.undo()
    eq(original, content())
  end)

  test('surround current line and unwrap without changing indentation', function()
    buffer('before\n  中文\nafter')
    at('中文')
    eq(true, tex.surround_environment('quote'))
    eq('before\n  \\begin{quote}\n  中文\n  \\end{quote}\nafter', content())
    at('中文')
    eq(true, tex.unwrap_environment())
    eq('before\n  中文\nafter', content())
  end)

  test('surround an explicit range and undo as one operation', function()
    buffer('before\nfirst\n中文\nafter')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.surround_environment('itemize', { line1 = 2, line2 = 3 }))
    eq('before\n\\begin{itemize}\nfirst\n中文\n\\end{itemize}\nafter', content())
    vim.cmd.undo()
    eq(original, content())
  end)

  test('surround command honors an Ex range', function()
    buffer('before\nfirst\nsecond\nafter')
    vim.cmd('2,3TexToolsSurroundEnvironment quote')
    eq('before\n\\begin{quote}\nfirst\nsecond\n\\end{quote}\nafter', content())
  end)

  test('visual surround uses the selected lines and supports backwards selection', function()
    buffer('before\nfirst\nsecond\nafter')
    at('second')
    local input = vim.ui.input
    vim.ui.input = function(_, callback)
      callback('quote')
    end
    keys('Vk,le')
    vim.ui.input = input
    eq('before\n\\begin{quote}\nfirst\nsecond\n\\end{quote}\nafter', content())
  end)

  test('surround rejects invalid names, ranges, and unmodifiable buffers', function()
    buffer('keep this')
    eq(false, tex.surround_environment('quote} injected'))
    eq(false, tex.surround_environment('quote', { line1 = 0 }))
    eq(false, tex.surround_environment('quote', { line1 = 1, line2 = 2 }))
    eq(false, tex.surround_environment('quote', { line1 = 0.5 }))
    vim.bo.modifiable = false
    eq(false, tex.surround_environment('quote'))
    vim.bo.modifiable = true
    eq('keep this', content())
  end)

  test('surround prompt refuses stale ranges', function()
    buffer('original')
    local callback
    local input, notify = vim.ui.input, vim.notify
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.surround_environment())
    vim.ui.input = input
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
    vim.notify = function() end
    callback('quote')
    vim.notify = notify
    eq('changed', content())
  end)

  test('surround prompt targets its original buffer after a buffer switch', function()
    local original = buffer('original')
    local callback
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.surround_environment())
    vim.ui.input = input
    buffer('other')
    callback('quote')
    eq('other', content())
    eq({ '\\begin{quote}', 'original', '\\end{quote}' }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
  end)

  test('unwrap the innermost environment and remove its options', function()
    buffer('\\begin{document}\n  \\begin{itemize}[nosep]\n  \\item 中文\n  \\end{itemize}\n\\end{document}')
    at('中文')
    eq(true, tex.unwrap_environment())
    eq('\\begin{document}\n  \\item 中文\n\\end{document}', content())
  end)

  for _, pair in ipairs({
    { 'prefix \\begin{quote}中文\\end{quote} suffix', 'prefix 中文 suffix' },
    { 'before\n\\begin{quote}\n\\end{quote}\nafter', 'before\nafter' },
    { '\\begin{quote}\n中文\n\\end{quote}', '中文' },
    { 'prefix \\begin{quote}中文\n\\end{quote}', 'prefix 中文' },
    { '\\begin{quote}\n中文\\end{quote} suffix', '中文 suffix' },
    { '\\begin{quote}\n\n中文\n\n\\end{quote}', '\n中文\n' },
    { '\\begin{quote}[\noption\n]\n中文\n\\end{quote}', '中文' },
  }) do
    test('unwrap preserves body and surrounding text: ' .. pair[1], function()
      buffer(pair[1])
      at('quote')
      eq(true, tex.unwrap_environment())
      eq(pair[2], content())
    end)
  end

  test('unwrap preserves comments after environment markers', function()
    buffer('\\begin{quote}% opening\n中文\n\\end{quote}% closing')
    at('中文')
    eq(true, tex.unwrap_environment())
    eq('% opening\n中文\n% closing', content())
  end)

  test('unwrap is one undo operation', function()
    buffer('\\begin{quote}\n中文\n\\end{quote}')
    at('中文')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.unwrap_environment())
    vim.cmd.undo()
    eq(original, content())
  end)

  test('unwrap rejects malformed and unmodifiable environments', function()
    buffer('\\begin{quote}\nx\n\\end{other}')
    at('x')
    eq(false, tex.unwrap_environment())
    buffer('\\begin{quote}\nx\n\\end{quote}')
    at('x')
    vim.bo.modifiable = false
    eq(false, tex.unwrap_environment())
    vim.bo.modifiable = true
  end)

  test('new queries support explicit buffers and positions', function()
    local bufnr = buffer('\\textbf{中文} $x$')
    buffer('elsewhere')
    eq({ 0, 8, 0, 14 }, tex.textobject_range('argument', true, { bufnr = bufnr, pos = { 0, 8 } }))
    eq({ 0, 17, 0, 18 }, tex.textobject_range('math', true, { bufnr = bufnr, pos = { 0, 17 } }))
    eq(nil, tex.textobject_range('unknown', false))
  end)

  test('new commands and Plug mappings are available without default keys', function()
    tex.setup({ mappings = false })
    buffer('x')
    local commands = vim.api.nvim_buf_get_commands(0, {})
    assert(commands.TexToolsSurroundEnvironment)
    assert(commands.TexToolsUnwrapEnvironment)
    assert(commands.TexToolsToggleMathDelimiters)
    eq('', vim.fn.maparg('ac', 'o'))
    eq('', vim.fn.maparg('dse', 'n'))
    assert(vim.fn.maparg('<Plug>(TexToolsAroundCommand)', 'o') ~= '')
    assert(vim.fn.maparg('<Plug>(TexToolsInsideArgument)', 'x') ~= '')
    assert(vim.fn.maparg('<Plug>(TexToolsAroundMath)', 'o') ~= '')
    tex.setup()
  end)
end
