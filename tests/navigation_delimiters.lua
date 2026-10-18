return function(h)
  local eq, buffer, at, content, keys = h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local function test(name, fn)
    h.test('bracket navigation: ' .. name, fn)
  end
  local function cursor(marker)
    local expected = vim.api.nvim_win_get_cursor(0)
    at(marker)
    eq(expected, vim.api.nvim_win_get_cursor(0))
  end
  for _, markers in ipairs({
    { '(', ')' },
    { '[', ']' },
    { '\\{', '\\}' },
    { '\\langle', '\\rangle' },
    { '\\lvert', '\\rvert' },
    { '\\lVert', '\\rVert' },
    { '\\left(', '\\right)' },
    { '\\left.', '\\right|' },
    { '\\left\\langle', '\\right\\rangle' },
    { '\\left[', '\\right)' },
  }) do
    test('round trip for ' .. markers[1], function()
      local source = '$' .. markers[1] .. ' 中文 ' .. markers[2] .. '$'
      buffer(source)
      at('中文')
      local origin = vim.api.nvim_win_get_cursor(0)
      eq(true, tex.jump_math_delimiter())
      cursor(markers[2])
      keys('``')
      eq(origin, vim.api.nvim_win_get_cursor(0))
      eq(true, tex.jump_math_delimiter())
      eq(true, tex.jump_math_delimiter())
      cursor(markers[1])
      eq(true, tex.jump_math_delimiter())
      cursor(markers[2])
      eq(source, content())
    end)
  end

  test('all bytes of sized closing markers return to the opening command', function()
    buffer('$\\left\\langle 中文 \\right\\rangle$')
    for _, offset in ipairs({ 0, 2, #'\\right', #'\\right\\rangle' - 1 }) do
      at('\\right', offset)
      eq(true, tex.jump_math_delimiter())
      cursor('\\left')
    end
  end)

  test('counts select enclosing pairs across command arguments', function()
    buffer('$\\left(\\frac{[中文]}{b}\\right)$')
    at('中文')
    keys(',ldm')
    cursor(']')
    keys(',ldm')
    cursor('[')
    at('中文')
    keys('2,ldm')
    cursor('\\right')
    at('中文')
    vim.cmd('2TexToolsJumpMathDelimiter')
    cursor('\\right')
    vim.cmd('TexToolsJumpMathDelimiter')
    cursor('\\left')
    at('中文')
    vim.cmd('TexToolsJumpMathDelimiter')
    cursor(']')
  end)

  test('multiline marker whitespace and comments are preserved', function()
    local source = '\\[\n\\left % left comment\n( 中文\n\\right % right comment\n)\n\\]'
    buffer(source)
    at('中文')
    eq(true, tex.jump_math_delimiter())
    cursor('\\right')
    at(')')
    eq(true, tex.jump_math_delimiter())
    cursor('\\left')
    eq(source, content())
  end)

  test('opens destination folds and works without modifying the buffer', function()
    buffer('\\[\n\\left(\n中文\n\\right)\n\\]')
    vim.wo.foldmethod = 'manual'
    vim.cmd('4,5fold')
    at('中文')
    local origin = vim.api.nvim_win_get_cursor(0)
    vim.bo.modifiable = false
    local ok = tex.jump_math_delimiter()
    vim.bo.modifiable = true
    eq(true, ok)
    cursor('\\right')
    eq(-1, vim.fn.foldclosed(4))
    keys('<C-o>')
    eq(origin, vim.api.nvim_win_get_cursor(0))
    vim.cmd('normal! zE')
  end)

  for index, fixture in ipairs({
    { 'outside (body)', 'body' },
    { '$\\text{(body)}$', 'body' },
    { '$x % (comment)\n$', 'comment' },
    { '\\begin{verbatim}\n$(body)$\n\\end{verbatim}', 'body' },
    { '$(unfinished$', 'unfinished' },
    { '$(mismatch]$', 'mismatch' },
    { '$\\left(x$', 'x' },
    { '$\\bigl(x\\bigr)$', 'x' },
    { '$\\foo[body]$', 'body' },
    { '$\\sqrt[3]{x}$', '3' },
    { '$\\foo{(x}{y)}$', 'x' },
    { '$(outer \\text{inner $[body]$})$', 'body', 2 },
  }) do
    test('invalid context or pair leaves navigation state untouched ' .. index, function()
      buffer(fixture[1])
      at(fixture[2])
      local before, jumps = vim.api.nvim_win_get_cursor(0), vim.fn.getjumplist()
      local ok, err = tex.jump_math_delimiter(fixture[3])
      eq(false, ok)
      assert(type(err) == 'string')
      eq(before, vim.api.nvim_win_get_cursor(0))
      eq(jumps, vim.fn.getjumplist())
      eq(fixture[1], content())
    end)
  end

  test('rejects invalid counts and reports a missing parser', function()
    buffer('$(body)$')
    at('body')
    local before, jumps = vim.api.nvim_win_get_cursor(0), vim.fn.getjumplist()
    for _, count in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, '2', false }) do
      local ok, err = tex.jump_math_delimiter(count)
      eq(false, ok)
      eq('Count must be a positive integer', err)
    end
    eq(false, tex.jump_math_delimiter(1000000000))
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    local ok, err = tex.jump_math_delimiter()
    eq(false, ok)
    assert(err:find('parser unavailable', 1, true))
    eq(before, vim.api.nvim_win_get_cursor(0))
    eq(jumps, vim.fn.getjumplist())
  end)

  test('disabled defaults retain commands and Plug mappings', function()
    tex.setup({ mappings = false })
    buffer('$[body]$')
    eq('', vim.fn.maparg(',ldm', 'n'))
    assert(vim.fn.maparg('<Plug>(TexToolsJumpMathDelimiter)', 'n') ~= '')
    at('body')
    keys('<Plug>(TexToolsJumpMathDelimiter)')
    cursor(']')
    vim.cmd.TexToolsJumpMathDelimiter()
    cursor('[')
    tex.setup()
  end)

  test('existing user mapping is preserved', function()
    buffer('$[body]$')
    vim.keymap.set('n', ',ldm', '<Nop>', { buffer = true })
    tex.setup()
    eq('<Nop>', vim.fn.maparg(',ldm', 'n'))
  end)
end
