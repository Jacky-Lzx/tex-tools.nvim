return function(h)
  local eq, buffer, at, content, keys = h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local function test(name, fn)
    h.test('counted text objects: ' .. name, fn)
  end
  local function selected(kind, inner, opts)
    local range, err = tex.textobject_range(kind, inner, opts)
    assert(range, err)
    local sr, sc, er, ec = unpack(range)
    return table.concat(vim.api.nvim_buf_get_text(opts and opts.bufnr or 0, sr, sc, er, ec, {}), '\n')
  end

  local cases = {
    {
      kind = 'environment',
      key = 'e',
      source = '\\begin{document}\\begin{quote}[wide]\\begin{center}中文\\end{center}\\end{quote}\\end{document}',
      outer = {
        '\\begin{center}中文\\end{center}',
        '\\begin{quote}[wide]\\begin{center}中文\\end{center}\\end{quote}',
        '\\begin{document}\\begin{quote}[wide]\\begin{center}中文\\end{center}\\end{quote}\\end{document}',
      },
      inner = {
        '中文',
        '\\begin{center}中文\\end{center}',
        '\\begin{quote}[wide]\\begin{center}中文\\end{center}\\end{quote}',
      },
    },
    {
      kind = 'command',
      key = 'c',
      source = '\\section*[Short]{before \\textbf{\\emph{中文}} after}\nbody \\LaTeX',
      outer = {
        '\\emph{中文}',
        '\\textbf{\\emph{中文}}',
        '\\section*[Short]{before \\textbf{\\emph{中文}} after}',
      },
      inner = { 'emph', 'textbf', 'section*' },
    },
    {
      kind = 'argument',
      key = 'a',
      source = '\\section[Short]{before \\textbf{{中文}} after}',
      outer = { '{中文}', '{{中文}}', '{before \\textbf{{中文}} after}' },
      inner = { '中文', '{中文}', 'before \\textbf{{中文}} after' },
    },
    {
      kind = 'math',
      key = '$',
      source = '\\begin{align*}x + \\text{outer $y + \\text{inner $中文$}$}\\end{align*}',
      outer = {
        '$中文$',
        '$y + \\text{inner $中文$}$',
        '\\begin{align*}x + \\text{outer $y + \\text{inner $中文$}$}\\end{align*}',
      },
      inner = { '中文', 'y + \\text{inner $中文$}', 'x + \\text{outer $y + \\text{inner $中文$}$}' },
    },
    {
      kind = 'delimiter',
      key = 'd',
      source = '$\\left(\\{[中文]\\}\\right)$',
      outer = { '[中文]', '\\{[中文]\\}', '\\left(\\{[中文]\\}\\right)' },
      inner = { '中文', '[中文]', '\\{[中文]\\}' },
    },
  }

  for _, case in ipairs(cases) do
    test(case.kind .. ' range queries count only enclosing objects of the same kind', function()
      buffer(case.source)
      at('中文')
      eq(case.outer[1], selected(case.kind, false))
      for count = 1, 3 do
        eq(case.outer[count], selected(case.kind, false, { count = count }))
        eq(case.inner[count], selected(case.kind, true, { count = count }))
      end
      for _, count in ipairs({ 4, 1000000000 }) do
        local range, err = tex.textobject_range(case.kind, false, { count = count })
        eq(nil, range)
        assert(type(err) == 'string')
      end
      eq(case.source, content())
    end)

    for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
      test(case.kind .. ' real operators and Visual mappings with selection=' .. selection, function()
        vim.o.selection = selection
        buffer(case.source)
        at('中文')
        keys('y2a' .. case.key)
        eq(case.outer[2], vim.fn.getreg('"'))
        at('中文')
        keys('2yi' .. case.key)
        eq(case.inner[2], vim.fn.getreg('"'))
        at('中文')
        keys('v3a' .. case.key .. 'y')
        eq(case.outer[3], vim.fn.getreg('"'))
        at('中文')
        keys('d2a' .. case.key)
        local first, last = case.source:find(case.outer[2], 1, true)
        eq(case.source:sub(1, first - 1) .. case.source:sub(last + 1), content())
      end)
    end

    test(case.kind .. ' excessive counts cancel delete and change without moving or touching registers', function()
      buffer(case.source)
      at('中文')
      local cursor, undo = vim.api.nvim_win_get_cursor(0), vim.fn.undotree().seq_cur
      vim.fn.setreg('"', 'keep')
      local messages = {}
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      keys('d9a' .. case.key)
      eq(case.source, content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
      eq('keep', vim.fn.getreg('"'))
      eq(undo, vim.fn.undotree().seq_cur)
      keys('c9i' .. case.key)
      eq('n', vim.fn.mode())
      eq(case.source, content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
      eq('keep', vim.fn.getreg('"'))
      eq(undo, vim.fn.undotree().seq_cur)
      eq(
        true,
        vim.wait(100, function()
          return #messages == 2
        end, 1)
      )
    end)
  end

  test('operator and motion counts multiply to select the requested depth', function()
    buffer('before \\one{\\two{\\three{\\four{中文}}}} after')
    at('中文')
    keys('2d2ac')
    eq('before  after', content())
  end)

  test('counted operators retain native dot repeat and undo', function()
    buffer('\\outer{\\inner{first}}\n\\second{\\third{中文}}')
    at('first')
    keys('d2ac')
    eq('\n\\second{\\third{中文}}', content())
    at('中文')
    keys('.')
    eq('\n', content())
    keys('u')
    eq('\n\\second{\\third{中文}}', content())
  end)

  test('failed counted operators preserve the preceding native dot', function()
    buffer('\\outer{\\inner{中文}}\nplain')
    at('plain')
    keys('A!<Esc>')
    at('中文')
    vim.notify = function() end
    keys('d9ac')
    at('plain')
    keys('.')
    eq('\\outer{\\inner{中文}}\nplain!!', content())
    vim.wait(1)
  end)

  test('a count on native dot overrides the saved text-object depth', function()
    buffer('\\outer{\\inner{first}}\n\\one{\\two{\\three{中文}}}')
    at('first')
    keys('d2ac')
    at('中文')
    keys('3.')
    eq('\n', content())
  end)

  test('failed counted operators preserve the preceding structural dot', function()
    buffer('\\textbf{first}\n\\textit{中文}')
    at('first')
    eq(true, tex.rename_command('emph'))
    vim.notify = function() end
    keys('d9ac')
    at('中文')
    keys('.')
    eq('\\emph{first}\n\\emph{中文}', content())
    vim.wait(1)
  end)

  test('standalone environment marker lines and begin options stay out of the inner range', function()
    buffer('\\begin{quote}[wide]\n\\begin{center}\n  中文\n\\end{center}\n\\end{quote}')
    at('中文')
    eq('\\begin{center}\n  中文\n\\end{center}', selected('environment', true, { count = 2 }))
    keys('y2ie')
    eq('\\begin{center}\n  中文\n\\end{center}', vim.fn.getreg('"'))
  end)

  test('command counts never include a section body as a command argument', function()
    buffer('\\section{Title}\n\\textbf{\\emph{中文}}')
    at('中文')
    eq('\\textbf{\\emph{中文}}', selected('command', false, { count = 2 }))
    eq(nil, tex.textobject_range('command', false, { count = 3 }))
  end)

  test('optional and curly groups share argument depth without selecting sibling options', function()
    buffer('\\outer{\\section[Short]{Title}}')
    at('Short')
    eq('[Short]', selected('argument', false, { count = 1 }))
    eq('{\\section[Short]{Title}}', selected('argument', false, { count = 2 }))
    at('Title')
    eq('{Title}', selected('argument', false, { count = 1 }))
    eq('{\\section[Short]{Title}}', selected('argument', false, { count = 2 }))
  end)

  test('custom math environments count while nonmath environments do not', function()
    tex.setup({ math_environments = { 'custom' } })
    buffer(
      '\\begin{document}\\begin{custom*}\\begin{group}\\text{words $中文$}\\end{group}\\end{custom*}\\end{document}'
    )
    at('中文')
    eq(
      '\\begin{custom*}\\begin{group}\\text{words $中文$}\\end{group}\\end{custom*}',
      selected('math', false, { count = 2 })
    )
    eq(nil, tex.textobject_range('math', false, { count = 3 }))
    tex.setup()
  end)

  test('plain bracket pairs in the same syntax scope have distinct depths', function()
    buffer('$(a+[b+\\{中文\\}])$')
    at('中文')
    for count, expected in ipairs({ '\\{中文\\}', '[b+\\{中文\\}]', '(a+[b+\\{中文\\}])' }) do
      eq(expected, selected('delimiter', false, { count = count }))
    end
    eq(nil, tex.textobject_range('delimiter', false, { count = 4 }))
  end)

  test('bracket counts cross atomic command arguments without counting text wrappers twice', function()
    buffer('$(\\frac{[中文]}{b})$')
    at('中文')
    eq('[中文]', selected('delimiter', false, { count = 1 }))
    eq('(\\frac{[中文]}{b})', selected('delimiter', false, { count = 2 }))
    eq(nil, tex.textobject_range('delimiter', false, { count = 3 }))
  end)

  test('sized brackets and plain brackets share depth in nesting order', function()
    buffer('$(\\left[\\{中文\\}\\right])$')
    at('中文')
    for count, expected in ipairs({ '\\{中文\\}', '\\left[\\{中文\\}\\right]', '(\\left[\\{中文\\}\\right])' }) do
      eq(expected, selected('delimiter', false, { count = count }))
    end
  end)

  test('bracket counts stay in the nearest formula', function()
    buffer('$(a+\\text{inner $[中文]$})$')
    at('中文')
    eq('[中文]', selected('delimiter', false))
    eq(nil, tex.textobject_range('delimiter', false, { count = 2 }))
  end)

  test('unsafe bracket spellings and optional arguments cannot be bypassed by a count', function()
    buffer('$\\bigl([中文]\\bigr)$')
    at('中文')
    eq('[中文]', selected('delimiter', false))
    eq(nil, tex.textobject_range('delimiter', false, { count = 2 }))
    buffer('$(\\foo[中文])$')
    at('中文')
    eq(nil, tex.textobject_range('delimiter', false, { count = 2 }))
  end)

  test('invalid enclosing environment markers are refused for both environment and formula objects', function()
    buffer('\\begin{align}\\text{words $中文$}\\end{wrong}')
    at('中文')
    eq('$中文$', selected('math', false))
    eq(nil, tex.textobject_range('math', false, { count = 2 }))
    buffer('\\begin{quote}\\begin{center}中文\\end{center}\\end{wrong}')
    at('中文')
    eq('\\begin{center}中文\\end{center}', selected('environment', false))
    eq(nil, tex.textobject_range('environment', false, { count = 2 }))
  end)

  for _, fixture in ipairs({
    { 'argument', '\\outer{\\inner{}}', '{}', '\\inner{}' },
    {
      'environment',
      '\\begin{quote}\\begin{center}\\end{center}\\end{quote}',
      'center',
      '\\begin{center}\\end{center}',
    },
    { 'math', '\\[a+\\text{\\(\\)}\\]', '\\(', 'a+\\text{\\(\\)}' },
    { 'delimiter', '$([])$', '[', '[]' },
  }) do
    test('empty innermost ' .. fixture[1] .. ' still counts as a level', function()
      buffer(fixture[2])
      at(fixture[3])
      eq(nil, tex.textobject_range(fixture[1], true))
      eq(fixture[4], selected(fixture[1], true, { count = 2 }))
    end)
  end

  for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    test('multiline UTF-8 and combining marks remain intact with selection=' .. selection, function()
      vim.o.selection = selection
      buffer('\\outer{first\n\\inner{中文} é}')
      at('中文')
      keys('y2ia')
      eq('first\n\\inner{中文} é', vim.fn.getreg('"'))
    end)
  end

  test('range queries support a hidden buffer and do not mutate options or the current buffer', function()
    local bufnr = buffer('中文 \\outer{\\inner{body}}')
    local pos = { 0, #'中文 \\outer{\\inner{' }
    buffer('elsewhere')
    local opts = { bufnr = bufnr, pos = pos, count = 2 }
    local original, cursor = vim.deepcopy(opts), vim.api.nvim_win_get_cursor(0)
    eq('\\outer{\\inner{body}}', selected('command', false, opts))
    eq('\\inner{body}', selected('argument', true, opts))
    eq(original, opts)
    eq('elsewhere', content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
  end)

  test('range and selection APIs reject invalid counts without changing text or cursor', function()
    buffer('\\outer{\\inner{中文}}')
    at('中文')
    local original, cursor = content(), vim.api.nvim_win_get_cursor(0)
    for _, case in ipairs(cases) do
      for _, count in ipairs({ 0, -1, 1.5, math.huge, -math.huge, 0 / 0, '2', false, {} }) do
        local range, err = tex.textobject_range(case.kind, false, { count = count })
        eq(nil, range)
        eq('Count must be a positive integer', err)
      end
    end
    eq(false, tex.select_textobject('command', false, 0))
    keys('')
    eq(original, content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
  end)

  test('selection API takes an explicit depth and defaults to the innermost object', function()
    buffer('\\outer{\\inner{中文}}')
    at('中文')
    eq(true, tex.select_textobject('command', false, 2))
    keys('y')
    eq('\\outer{\\inner{中文}}', vim.fn.getreg('"'))
    at('中文')
    eq(true, tex.select_textobject('command', false))
    keys('y')
    eq('\\inner{中文}', vim.fn.getreg('"'))
  end)

  test('counted selections and yanks work in unmodifiable buffers', function()
    buffer('\\outer{\\inner{中文}}')
    at('中文')
    vim.bo.modifiable = false
    local range = tex.textobject_range('argument', true, { count = 2 })
    keys('y2ia')
    local result = vim.fn.getreg('"')
    vim.bo.modifiable = true
    assert(range)
    eq('\\inner{中文}', result)
  end)

  test('missing parsers fail all counted range queries without moving', function()
    buffer('\\outer{\\inner{中文}}')
    at('中文')
    local cursor = vim.api.nvim_win_get_cursor(0)
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    for _, case in ipairs(cases) do
      local range, err = tex.textobject_range(case.kind, false, { count = 2 })
      eq(nil, range)
      assert(err:find('parser unavailable', 1, true))
    end
    eq(cursor, vim.api.nvim_win_get_cursor(0))
  end)

  test('counts cannot escape comments or literal content through enclosing structures', function()
    for _, source in ipairs({
      '\\outer{\\inner{ % 中文\n}}',
      '\\begin{verbatim}\n\\outer{\\inner{中文}}\n\\end{verbatim}',
    }) do
      buffer(source)
      at('中文')
      for _, kind in ipairs({ 'command', 'argument', 'math', 'delimiter' }) do
        eq(nil, tex.textobject_range(kind, false, { count = 2 }))
      end
    end
  end)

  test('counted Plug mappings remain available with default mappings disabled', function()
    tex.setup({ mappings = false })
    buffer('\\outer{\\inner{中文}}', 'plaintex')
    at('中文')
    eq('', vim.fn.maparg('ac', 'o'))
    keys('y2<Plug>(TexToolsAroundCommand)')
    eq('\\outer{\\inner{中文}}', vim.fn.getreg('"'))
    at('中文')
    keys('v2<Plug>(TexToolsInsideArgument)y')
    eq('\\inner{中文}', vim.fn.getreg('"'))
    tex.setup()
  end)
end
