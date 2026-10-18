return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function selected(inner, opts)
    local range, err = tex.textobject_range('delimiter', inner, opts)
    assert(range, err)
    local sr, sc, er, ec = unpack(range)
    return table.concat(vim.api.nvim_buf_get_text(opts and opts.bufnr or 0, sr, sc, er, ec, {}), '\n')
  end

  local fixtures = {
    { '$a+(x+[y])+z$', 'y', '[y]', 'y' },
    { '$a+(x+[y])+z$', 'x+', '(x+[y])', 'x+[y]' },
    { '$\\left( x+\\left[y\\right] \\right)$', 'y', '\\left[y\\right]', 'y' },
    { '$\\left( x+\\left[y\\right] \\right)$', 'x+', '\\left( x+\\left[y\\right] \\right)', ' x+\\left[y\\right] ' },
    { '$\\left( (x) \\right)$', 'x', '(x)', 'x' },
    { '$x+(\\frac{a}{b})$', 'a}', '(\\frac{a}{b})', '\\frac{a}{b}' },
    { '$\\{中文\\}$', '中文', '\\{中文\\}', '中文' },
    { '$\\langle{x}\\rangle$', 'x', '\\langle{x}\\rangle', '{x}' },
    { '$\\left. x \\right|$', 'x', '\\left. x \\right|', ' x ' },
    { '$\\left( x \\right]$', 'x', '\\left( x \\right]', ' x ' },
    {
      '\\[\n  (first % ignored )\n  中文)\n\\]',
      '中文',
      '(first % ignored )\n  中文)',
      'first % ignored )\n  中文',
    },
    { '\\begin{align}\nx &= (a+b) \\\\\n y &= z\n\\end{align}', 'a+b', '(a+b)', 'a+b' },
  }
  for i, fixture in ipairs(fixtures) do
    test('math delimiter text objects choose the innermost pair ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(fixture[3], selected(false))
      eq(fixture[4], selected(true))
    end)
  end

  test('word-shaped sized markers preserve adjacent body and following text', function()
    buffer('$\\left|中文\\right|tail$')
    at('中文')
    eq('\\left|中文\\right|', selected(false))
    eq('中文', selected(true))
    at('tail')
    eq(nil, tex.textobject_range('delimiter', false))
    at('中文')
    eq(true, tex.change_math_delimiters('bracket'))
    eq('$\\left[中文\\right]tail$', content())
    buffer('$\\left.x\\right|$')
    at('x')
    eq('x', selected(true))
    eq(true, tex.unwrap_math_delimiters())
    eq('$x$', content())
  end)

  test('math delimiters can be edited inside an inline formula nested in text mode', function()
    buffer('$a+\\text{words $(x)$}+(y)$')
    at('(x)', 1)
    eq(true, tex.toggle_math_delimiter_size())
    eq('$a+\\text{words $\\left(x\\right)$}+(y)$', content())
  end)

  test('parentheses in a math environment header are not math delimiters', function()
    tex.setup({ math_environments = { 'custommath' } })
    buffer('\\begin{custommath}[(c)]\nx\n\\end{custommath}')
    at('(c)', 1)
    eq(nil, tex.textobject_range('delimiter', false))
    eq(false, tex.change_math_delimiters('bracket'))
    tex.setup()
  end)

  test('known optional groups are excluded from delimiter text objects', function()
    buffer('$\\section[Title]{x}$')
    at('Title')
    eq(nil, tex.textobject_range('delimiter', false))
  end)

  for _, fixture in ipairs({
    '\\begin{align}\n(a & b)\n\\end{align}',
    '\\begin{align}\n(a \\\\\n b)\n\\end{align}',
  }) do
    test('automatic sizing refuses to span alignment cells or rows: ' .. fixture, function()
      buffer(fixture)
      at('(a', 1)
      eq('(a' .. (fixture:find('&', 1, true) and ' & b)' or ' \\\\\n b)'), selected(false))
      eq(false, tex.toggle_math_delimiter_size())
      eq(fixture, content())
    end)
  end

  test('both delimiter markers belong to the outer text object', function()
    buffer('$\\left[中文\\right]$')
    for _, marker in ipairs({ '\\left', '[', '\\right', ']' }) do
      at(marker)
      eq('\\left[中文\\right]', selected(false))
    end
    buffer('$(x)$')
    at(')')
    eq('(x)', selected(false))
  end)

  local refusals = {
    { 'plain (x)', 'x' },
    { '$\\text{words (x)}$', 'x' },
    { '$x % (ignored)\n$', 'ignored' },
    { '\\iffalse\n$(ignored)$\n\\fi', 'ignored' },
    { '\\begin{verbatim}\n$(ignored)$\n\\end{verbatim}', 'ignored' },
    { '\\begin{comment}\n$(ignored)$\n\\end{comment}', 'ignored' },
    { '$(a]$', 'a' },
    { '$x+(unfinished$', 'unfinished' },
    { '$\\left(x$', 'x' },
    { '$\\left(x\\bigr)$', 'x' },
    { '$\\bigl(x\\bigr)$', 'x' },
    { '$\\big(x\\big)$', 'x' },
    { '$\\Bigg[x\\Bigg]$', 'x' },
    { '$\\left\\custom x\\right)$', 'x' },
    { '$\\sqrt[3]{x}$', '3' },
    { '$\\foo{(x}{y)}$', 'x' },
    { '$|x|$', 'x' },
    { '$\\left(x\\right)$', '$' },
  }
  for i, fixture in ipairs(refusals) do
    test('math delimiter operations refuse unsafe contexts ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      local original, cursor = content(), vim.api.nvim_win_get_cursor(0)
      eq(nil, tex.textobject_range('delimiter', false))
      eq(false, tex.change_math_delimiters('bracket'))
      eq(false, tex.unwrap_math_delimiters())
      eq(false, tex.toggle_math_delimiter_size())
      eq(original, content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  local targets = {
    { 'paren', '(', ')' },
    { 'bracket', '[', ']' },
    { 'brace', '\\{', '\\}' },
    { 'angle', '\\langle ', '\\rangle' },
    { 'vert', '\\lvert ', '\\rvert' },
    { 'Vert', '\\lVert ', '\\rVert' },
  }
  for _, target in ipairs(targets) do
    for _, automatic in ipairs({ false, true }) do
      test('change both math delimiters to ' .. target[1] .. ' automatic=' .. tostring(automatic), function()
        buffer(automatic and '$\\left(x\\right)y$' or '$(x)y$')
        at('x')
        eq(true, tex.change_math_delimiters(target[1]))
        local right = target[3] .. (target[3]:match('\\[A-Za-z]+$') and ' ' or '')
        eq(
          '$' .. (automatic and '\\left' or '') .. target[2] .. 'x' .. (automatic and '\\right' or '') .. right .. 'y$',
          content()
        )
      end)
    end
  end

  for alias, name in pairs({
    ['('] = 'paren',
    ['['] = 'bracket',
    ['{'] = 'brace',
    ['<'] = 'angle',
    ['|'] = 'vert',
    ['\\|'] = 'Vert',
  }) do
    test('math delimiter change accepts alias ' .. alias, function()
      buffer('$(x)$')
      at('x')
      eq(true, tex.change_math_delimiters(alias))
      local result = content()
      buffer('$(x)$')
      at('x')
      eq(true, tex.change_math_delimiters(name))
      eq(result, content())
    end)
  end

  test('change preserves marker whitespace and comments', function()
    buffer('$\\left % left\n (中文 \\right % right\n )$')
    at('中文')
    eq(true, tex.change_math_delimiters('brace'))
    eq('$\\left % left\n \\{中文 \\right % right\n \\}$', content())
    eq(false, tex.unwrap_math_delimiters())
    eq(true, tex.toggle_math_delimiter_size())
    eq('$ % left\n \\{中文  % right\n \\}$', content())
  end)

  local unwraps = {
    { '中文 $a+(x+[y])+z$ 后文', 'x+', '中文 $a+x+[y]+z$ 后文' },
    { '$\\left(中文 \\frac{a}{b}\\right)$', '中文', '$中文 \\frac{a}{b}$' },
    { '$\\left(\\right)$', '\\left', '$$' },
    { '$(first % keep\nsecond)$', 'first', '$first % keep\nsecond$' },
    { '$\\left. x \\right|$', 'x', '$ x $' },
    { '$\\left(x\\right]$', 'x', '$x$' },
    { '$\\{x\\}$', 'x', '$x$' },
  }
  for i, fixture in ipairs(unwraps) do
    test('unwrap math delimiters preserves exact body ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(true, tex.unwrap_math_delimiters())
      eq(fixture[3], content())
    end)
  end

  for i, fixture in ipairs({
    { '$\\alpha(x)$', 'x' },
    { '$(\\alpha)x$', '\\alpha' },
    { '$\\alpha()x$', '(' },
    { '$\\alpha\\left(x\\right)$', 'x' },
    { '$\\left(\\alpha\\right)x$', '\\alpha' },
  }) do
    test('math unwrap refuses control word merging ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(false, tex.unwrap_math_delimiters())
      eq(fixture[1], content())
    end)
  end

  for _, fixture in ipairs({
    '$(x)$',
    '$[x]$',
    '$\\{x\\}$',
    '$\\langle x\\rangle$',
    '$\\lvert x\\rvert$',
    '$\\lVert x\\rVert$',
    '$\\langle{x}\\rangle$',
  }) do
    test('automatic delimiter sizing round trip: ' .. fixture, function()
      buffer(fixture)
      at('x')
      eq(true, tex.toggle_math_delimiter_size())
      assert(content():find('\\left', 1, true))
      at('x')
      eq(true, tex.toggle_math_delimiter_size())
      eq(fixture, content())
    end)
  end

  test('size toggle preserves whitespace within explicit markers', function()
    buffer('$\\left ( x \\right )$')
    at('x')
    eq(true, tex.toggle_math_delimiter_size())
    eq('$ ( x  )$', content())
  end)

  for _, fixture in ipairs({ '$\\left.x\\right|$', '$\\left(x\\right]$', '$\\left|x\\right|$' }) do
    test('size toggle refuses ambiguous or invisible plain delimiters: ' .. fixture, function()
      buffer(fixture)
      at('x')
      eq(false, tex.toggle_math_delimiter_size())
      eq(fixture, content())
      eq(true, tex.change_math_delimiters('bracket'))
    end)
  end

  test('middle remains attached to its left/right pair', function()
    buffer('$\\left(x\\middle|y\\right)$')
    at('x')
    eq(false, tex.toggle_math_delimiter_size())
    eq(false, tex.unwrap_math_delimiters())
    eq(true, tex.change_math_delimiters('bracket'))
    eq('$\\left[x\\middle|y\\right]$', content())
  end)

  test('nested middle does not prevent editing the outer pair', function()
    buffer('$\\left(x+\\left[y\\middle|z\\right]\\right)$')
    at('x')
    eq(true, tex.toggle_math_delimiter_size())
    eq('$(x+\\left[y\\middle|z\\right])$', content())
    at('x')
    eq(true, tex.unwrap_math_delimiters())
    eq('$x+\\left[y\\middle|z\\right]$', content())
  end)

  for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    test('delimiter operator mappings support UTF-8 with selection=' .. selection, function()
      vim.o.selection = selection
      buffer('$\\left[中文\\right]$')
      at('中文')
      keys('did')
      eq('$\\left[\\right]$', content())
      buffer('$(中文)$')
      at('中文')
      keys('dad')
      eq('$$', content())
    end)
  end

  test('empty delimiters have only an outer text object', function()
    buffer('$( )+[]$')
    at('[')
    eq('[]', selected(false))
    eq(nil, tex.textobject_range('delimiter', true))
    eq(true, tex.unwrap_math_delimiters())
    eq('$( )+$', content())
  end)

  for index, operation in ipairs({
    function()
      return tex.change_math_delimiters('angle')
    end,
    tex.unwrap_math_delimiters,
    tex.toggle_math_delimiter_size,
  }) do
    test('math delimiter editing is a single undo step ' .. index, function()
      buffer('$\\left(中文\\right)$')
      at('中文')
      local original = content()
      vim.cmd('let &undolevels = &undolevels')
      eq(true, operation())
      vim.cmd.undo()
      eq(original, content())
    end)
  end

  test('delimiter prompt cancellation and invalid target preserve text', function()
    buffer('$(x)$')
    at('x')
    for _, value in ipairs({ false, '', 'bad', '\\input{evil}', 12 }) do
      eq(false, tex.change_math_delimiters(value))
      eq('$(x)$', content())
    end
    for _, value in ipairs({ false, '' }) do
      vim.ui.input = function(_, callback)
        callback(value or nil)
      end
      eq(true, tex.change_math_delimiters())
      eq('$(x)$', content())
    end
  end)

  test('delimiter prompt defaults to the current shape and edits original buffer', function()
    local original = buffer('$[x]$')
    at('x')
    local callback
    vim.ui.input = function(opts, cb)
      eq({ prompt = 'Delimiter: ', default = 'bracket' }, opts)
      callback = cb
    end
    eq(true, tex.change_math_delimiters())
    buffer('elsewhere')
    callback('brace')
    eq('elsewhere', content())
    eq('$\\{x\\}$', table.concat(vim.api.nvim_buf_get_lines(original, 0, -1, false), '\n'))
  end)

  test('delimiter prompt rejects stale ranges', function()
    buffer('$(x)$')
    at('x')
    local callback, message
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.change_math_delimiters())
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '$(changed)$' })
    vim.notify = function(value)
      message = value
    end
    callback('bracket')
    eq('$(changed)$', content())
    assert(message:find('Buffer changed', 1, true))
  end)

  test('delimiter inspection works with explicit buffer/position and custom math environments', function()
    tex.setup({ math_environments = { 'custommath' } })
    local bufnr = buffer('\\begin{custommath}\n(x)\n\\end{custommath}')
    buffer('elsewhere')
    eq('(x)', selected(false, { bufnr = bufnr, pos = { 1, 1 } }))
    tex.setup()
  end)

  test('delimiter text objects work in unmodifiable buffers but edits fail', function()
    buffer('$(x)$')
    at('x')
    vim.bo.modifiable = false
    eq('(x)', selected(false))
    eq(false, tex.change_math_delimiters('bracket'))
    eq(false, tex.unwrap_math_delimiters())
    eq(false, tex.toggle_math_delimiter_size())
    vim.bo.modifiable = true
  end)

  test('math delimiter editing reports missing parser', function()
    buffer('$(x)$')
    at('x')
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    local ok, err = tex.toggle_math_delimiter_size()
    eq(false, ok)
    assert(err:find('parser unavailable', 1, true))
    eq('$(x)$', content())
  end)

  test('math delimiter Ex commands and default mappings', function()
    tex.setup()
    buffer('$(x)$')
    at('x')
    vim.cmd('TexToolsChangeMathDelimiters bracket')
    eq('$[x]$', content())
    at('x')
    keys(',ldt')
    eq('$\\left[x\\right]$', content())
    at('x')
    vim.cmd('TexToolsToggleMathDelimiterSize')
    eq('$[x]$', content())
    at('x')
    keys(',ldd')
    eq('$x$', content())
    buffer('$(x)$')
    at('x')
    vim.ui.input = function(_, cb)
      cb('brace')
    end
    keys(',ldc')
    eq('$\\{x\\}$', content())
    at('x')
    vim.cmd('TexToolsUnwrapMathDelimiters')
    eq('$x$', content())
  end)

  test('disabled defaults retain delimiter plugs and commands', function()
    tex.setup({ mappings = false })
    buffer('$(x)$')
    at('x')
    for _, spec in ipairs({ { ',ldc', 'n' }, { ',ldd', 'n' }, { ',ldt', 'n' }, { 'ad', 'o' }, { 'id', 'x' } }) do
      eq('', vim.fn.maparg(spec[1], spec[2]))
    end
    eq(true, vim.fn.maparg('<Plug>(TexToolsInsideMathDelimiter)', 'o') ~= '')
    eq(true, vim.fn.maparg('<Plug>(TexToolsChangeMathDelimiters)', 'n') ~= '')
    vim.cmd('TexToolsToggleMathDelimiterSize')
    eq('$\\left(x\\right)$', content())
    tex.setup()
  end)

  test('delimiter mappings preserve existing user mappings', function()
    vim.keymap.set('n', ',ldc', '<Nop>')
    vim.keymap.set('o', 'id', '<Nop>')
    buffer('$(x)$')
    eq('<Nop>', vim.fn.maparg(',ldc', 'n'))
    eq('<Nop>', vim.fn.maparg('id', 'o'))
    vim.keymap.del('n', ',ldc')
    vim.keymap.del('o', 'id')
  end)
end
