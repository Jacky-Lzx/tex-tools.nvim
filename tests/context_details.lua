return function(h)
  local eq, buffer, at, content, keys = h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local names = { 'in_subscript', 'in_superscript', 'in_numerator', 'in_denominator', 'in_table_cell' }
  local function test(name, fn)
    h.test('detailed context: ' .. name, fn)
  end
  local function check(expected)
    for _, name in ipairs(names) do
      local result, err = tex[name]()
      eq(expected[name] == true, result)
      eq(nil, err)
    end
  end

  for _, script in ipairs({ { '_', 'in_subscript' }, { '^', 'in_superscript' } }) do
    for _, value in ipairs({ 'i', '\\alpha', '{中文}', '{}' }) do
      test(script[2] .. ' recognizes payload ' .. value, function()
        buffer('$x' .. script[1] .. value .. '$')
        at(value, value:sub(1, 1) == '{' and 1 or 0)
        check({ [script[2]] = true })
        at(script[1])
        check({})
        if value:sub(1, 1) == '{' then
          at('{')
          check({})
          at('}')
          check({ [script[2]] = true })
        end
        at('$', #('$x' .. script[1] .. value))
        check({})
      end)
    end
  end

  test('nested scripts can satisfy both conditions within the nearest formula', function()
    buffer('$x^{a_{中文}}$')
    at('中文')
    check({ in_subscript = true, in_superscript = true })
  end)

  for _, command in ipairs({ '\\frac', '\\dfrac', '\\tfrac' }) do
    test('fraction parts for ' .. command, function()
      buffer('$' .. command .. '{中文 numerator}{denominator}$')
      at('numerator')
      check({ in_numerator = true })
      at('denominator')
      check({ in_denominator = true })
      at(command)
      check({})
      at('{')
      check({})
      at('}{')
      check({ in_numerator = true })
    end)
  end

  test('empty fraction groups support insertion just before the closing brace', function()
    buffer('$\\frac{}{}$')
    at('{}', 1)
    check({ in_numerator = true })
    at('}{}', 2)
    check({ in_denominator = true })
  end)

  test('fraction queries use the nearest known fraction rather than outer parts', function()
    buffer('$\\frac{outer}{\\frac{inner numerator}{inner denominator}}$')
    at('outer')
    check({ in_numerator = true })
    at('inner numerator')
    check({ in_numerator = true })
    at('inner denominator')
    check({ in_denominator = true })
    at('\\frac{inner')
    check({})
  end)

  test('only the first two braced fraction arguments have semantic roles', function()
    buffer('$\\frac{a}{b}{extra}$')
    at('extra')
    check({})
    buffer('$\\binom{a}{b}+\\customfrac{c}{d}+\\frac12$')
    for _, target in ipairs({ '{a}', '{b}', '{c}', '{d}', '12' }) do
      at(target, target:sub(1, 1) == '{' and 1 or 0)
      check({})
    end
  end)

  test('script and fraction roles compose', function()
    buffer('$x^{\\frac{a_i}{b_j}}$')
    at('a_i', 2)
    check({ in_subscript = true, in_superscript = true, in_numerator = true })
    at('b_j', 2)
    check({ in_subscript = true, in_superscript = true, in_denominator = true })
  end)

  test('text mode suppresses math roles and inner formulas start a new scope', function()
    buffer('$x^{\\frac{\\text{words $y_j$}}{b}}$')
    at('words')
    check({})
    at('y_j', 2)
    check({ in_subscript = true })
    at('b}')
    check({ in_superscript = true, in_denominator = true })
  end)

  test('custom math environments enable math roles', function()
    tex.setup({ math_environments = { 'custommath' } })
    buffer('\\begin{custommath*}x_i+\\frac{a}{b}\\end{custommath*}')
    at('x_i', 2)
    check({ in_subscript = true })
    at('{b}', 1)
    check({ in_denominator = true })
    tex.setup()
  end)

  for _, fixture in ipairs({
    { 'tabular', '[t]{lc}' },
    { 'tabular*', '{10cm}[t]{lc}' },
    { 'tabularx', '{\\linewidth}[b]{lc}' },
    { 'array', '[t]{cc}' },
    { 'matrix', '' },
    { 'pmatrix', '' },
    { 'bmatrix', '' },
    { 'Bmatrix', '' },
    { 'vmatrix', '' },
    { 'Vmatrix', '' },
    { 'smallmatrix', '' },
    { 'cases', '' },
    { 'aligned', '[t]' },
    { 'alignedat', '[t]{2}' },
    { 'align', '' },
    { 'align*', '' },
    { 'alignat', '{2}' },
    { 'flalign', '' },
    { 'split', '' },
  }) do
    test('table cells in ' .. fixture[1], function()
      buffer(
        '\\begin{'
          .. fixture[1]
          .. '}'
          .. fixture[2]
          .. '\n  first & second \\\\\n  third & fourth\n\\end{'
          .. fixture[1]
          .. '}'
      )
      for _, target in ipairs({ 'first', 'second', 'third', 'fourth' }) do
        at(target)
        eq(true, tex.in_table_cell())
      end
      for _, target in ipairs({ '\\begin', '\\end', '&', '\\\\' }) do
        at(target)
        eq(false, tex.in_table_cell())
      end
      if fixture[2] ~= '' then
        at('}' .. fixture[2], 1)
        eq(false, tex.in_table_cell())
      end
    end)
  end

  test('column specifications and their nested groups are not cells', function()
    buffer('\\begin{tabular}{>{\\bfseries}p{2cm}c}first & second\\end{tabular}')
    for _, target in ipairs({ 'bfseries', '2cm', '}first' }) do
      at(target)
      eq(false, tex.in_table_cell())
    end
    at('first')
    eq(true, tex.in_table_cell())
  end)

  test('row spacing and stars are not cells, including metadata on later lines', function()
    buffer(
      '\\begin{tabular}{cc}\na & b \\\\*[2pt]\nc & d \\tabularnewline[3pt]\ne & f \\\\\n[4pt]\ng & h\n\\end{tabular}'
    )
    for _, target in ipairs({ '\\\\', '*', '2pt', '3pt', '4pt', '\\tabularnewline' }) do
      at(target)
      eq(false, tex.in_table_cell())
    end
    for _, target in ipairs({ 'a &', 'c &', 'e &', 'g &' }) do
      at(target)
      eq(true, tex.in_table_cell())
    end
    buffer('\\begin{tabular}{cc}a & b \\tabularnewline*[5pt] c & d\\end{tabular}')
    at('5pt')
    eq(false, tex.in_table_cell())
    at('c &')
    eq(true, tex.in_table_cell())
    buffer('\\begin{tabular}{cc}a & b \\\\[unfinished\\end{tabular}')
    at('unfinished')
    eq(false, tex.in_table_cell())
  end)

  test('row-break command ownership does not hide the following braced cell', function()
    buffer('\\begin{matrix}a&b\\\\{next}&last\\end{matrix}')
    at('next')
    eq(true, tex.in_table_cell())
    at('\\\\')
    eq(false, tex.in_table_cell())
  end)

  test('nested group, command and formula separators remain inside their cells', function()
    buffer('\\begin{tabular}{cc}{a & b} & \\textbf{c & d} \\\\ $x\\&y$ & last\\end{tabular}')
    for _, target in ipairs({ 'a &', '& b', '& d', '\\&' }) do
      at(target)
      eq(true, tex.in_table_cell())
    end
  end)

  test('nested tables use their own header and unsupported nearest environments stop lookup', function()
    buffer('\\begin{tabular}{cc}outer & \\begin{array}{rr}inner&last\\end{array}\\end{tabular}')
    at('inner')
    eq(true, tex.in_table_cell())
    at('{rr}', 1)
    eq(false, tex.in_table_cell())
    buffer('\\begin{tabular}{cc}outer & \\begin{quote}words\\end{quote}\\end{tabular}')
    at('words')
    eq(false, tex.in_table_cell())
  end)

  test('known table rules are excluded from cell conditions', function()
    buffer('\\begin{tabular}{cc}\n\\toprule\na & b \\\\\n\\cline{1-2}\nc & d\n\\bottomrule\n\\end{tabular}')
    for _, target in ipairs({ 'toprule', '1-2', 'bottomrule' }) do
      at(target)
      eq(false, tex.in_table_cell())
    end
  end)

  test('table and math conditions compose independently', function()
    buffer('\\begin{array}{cc}x_i & \\frac{a}{b}\\end{array}')
    at('x_i', 2)
    check({ in_subscript = true, in_table_cell = true })
    at('{b}', 1)
    check({ in_denominator = true, in_table_cell = true })
  end)

  for index, fixture in ipairs({
    { 'outside x_i and \\frac{a}{b}', 'x_i', 2 },
    { '% $x_i+\\frac{a}{b}$', 'x_i', 2 },
    { '\\iffalse\n$x_i+\\frac{a}{b}$\n\\fi', 'x_i', 2 },
    { '\\begin{verbatim}\n$x_i+\\frac{a}{b}$\n\\end{verbatim}', 'x_i', 2 },
    { '$x^{', '^' },
    { '$\\frac{a}{', 'a' },
    { '\\begin{tabular}{cc}a&b\\end{wrong}', 'a&b' },
    { '\\begin{array}missing spec\\end{array}', 'missing' },
    { '\\begin{tabular}{cc}\na % ignored &\n\\end{tabular}', 'ignored' },
    { '\\begin{quote}a&b\\end{quote}', 'a&b' },
  }) do
    test('nonmatching or incomplete syntax returns false without errors ' .. index, function()
      buffer(fixture[1])
      at(fixture[2], fixture[3])
      check({})
    end)
  end

  test('current-cursor conditions work during actual Insert-mode input', function()
    buffer('$x^{}+\\frac{}{b}$')
    vim.keymap.set('i', '<F5>', function()
      return tex.in_superscript() and 'power' or tex.in_numerator() and 'num' or 'wrong'
    end, { buffer = true, expr = true })
    at('{}', 1)
    keys('i<F5><Esc>')
    at('\\frac{}', #'\\frac{')
    keys('i<F5><Esc>')
    eq('$x^{power}+\\frac{num}{b}$', content())
  end)

  test('hidden-buffer queries preserve all editor state and caller options', function()
    local bufnr = buffer('\\begin{array}{cc}x_i & \\frac{中文}{b}\\end{array}')
    buffer('elsewhere')
    local cursor, undo, jumps = vim.api.nvim_win_get_cursor(0), vim.fn.undotree().seq_cur, vim.fn.getjumplist()
    local opts = { bufnr = bufnr, pos = { 0, #'\\begin{array}{cc}x_i & \\frac{' } }
    local original = vim.deepcopy(opts)
    vim.notify = function()
      error('queries must not notify')
    end
    eq(true, tex.in_numerator(opts))
    eq(true, tex.in_table_cell(opts))
    eq(false, tex.in_denominator(opts))
    eq(false, tex.in_superscript(opts))
    eq(false, tex.in_subscript(opts))
    eq(original, opts)
    eq('elsewhere', content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
    eq(undo, vim.fn.undotree().seq_cur)
    eq(jumps, vim.fn.getjumplist())
    for _, name in ipairs(names) do
      local result, err = tex[name]({ bufnr = bufnr })
      eq(false, result)
      assert(err:find('Provide pos', 1, true))
    end
  end)

  test('queries reparse edits and work in unmodifiable buffers', function()
    local bufnr = buffer('$x_i$')
    eq(true, tex.in_subscript({ pos = { 0, 3 } }))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '$x^i$' })
    vim.bo.modifiable = false
    local subscript = tex.in_subscript({ pos = { 0, 3 } })
    local superscript = tex.in_superscript({ pos = { 0, 3 } })
    vim.bo.modifiable = true
    eq(false, subscript)
    eq(true, superscript)
  end)

  test('context snapshots share ancestor checks and follow configuration changes', function()
    buffer('\\begin{custom}\nx_i\n\\end{custom}')
    tex.setup({ math_environments = { 'custom' } })
    local context = require('tex-tools.context')
    local original, calls = context.is_math_environment, 0
    context.is_math_environment = function(...)
      calls = calls + 1
      return original(...)
    end
    local ok, err = pcall(function()
      local opts = { pos = { 1, 2 } }
      eq(true, tex.in_math(opts))
      local first = calls
      assert(first > 0)
      eq(false, tex.in_comment(opts))
      eq(true, tex.in_math(opts))
      eq(first, calls)
      tex.setup()
      eq(false, tex.in_math(opts))
      assert(calls > first)
      tex.setup({ math_environments = { 'custom*' } })
      eq(true, tex.in_math(opts))
      eq({ pos = { 1, 2 } }, opts)
    end)
    context.is_math_environment = original
    tex.setup()
    assert(ok, err)
  end)

  test('table snapshots follow cursor movement, edits, and buffer switches', function()
    local first = buffer('\\begin{tabular}{cc}\na & b \\\\[2pt]\nc & d \\\\\n\\end{tabular}')
    local environment = require('tex-tools.environment')
    local original, calls = environment.from_node, 0
    environment.from_node = function(...)
      calls = calls + 1
      return original(...)
    end
    local ok, err = pcall(function()
      eq(true, tex.in_table_cell({ pos = { 1, 0 } }))
      eq(false, tex.in_table_cell({ pos = { 1, 2 } }))
      eq(false, tex.in_table_cell({ pos = { 1, 9 } }))
      eq(true, tex.in_table_cell({ pos = { 2, 4 } }))
      eq(1, calls)
      vim.api.nvim_buf_set_lines(first, 1, 2, false, { 'a + b' })
      eq(true, tex.in_table_cell({ pos = { 1, 2 } }))
      eq(2, calls)
      local second = buffer('\\begin{matrix}\nx & y\n\\end{matrix}')
      eq(false, tex.in_table_cell({ bufnr = second, pos = { 1, 2 } }))
      eq(true, tex.in_table_cell({ bufnr = first, pos = { 1, 2 } }))
      vim.api.nvim_buf_set_lines(first, 0, 1, false, { '\\begin{quote}' })
      eq(false, tex.in_table_cell({ bufnr = first, pos = { 1, 2 } }))
    end)
    environment.from_node = original
    assert(ok, err)
  end)

  test('positions are clamped and missing parsers or invalid positions return errors', function()
    buffer('$x_i$')
    for _, name in ipairs(names) do
      local opts = { pos = { 0, 10000 } }
      eq(false, tex[name](opts))
      eq({ pos = { 0, 10000 } }, opts)
      for _, pos in ipairs({ { -1, 0 }, { 10, 0 }, { 0, -1 } }) do
        local result, err = tex[name]({ pos = pos })
        eq(false, result)
        eq('Position is outside the buffer', err)
      end
    end
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    for _, name in ipairs(names) do
      local result, err = tex[name]()
      eq(false, result)
      assert(err:find('parser unavailable', 1, true))
    end
  end)
end
