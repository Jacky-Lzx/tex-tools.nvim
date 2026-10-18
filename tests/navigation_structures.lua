return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function cursor(marker)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local col = line:find(marker, 1, true)
      if col then
        eq({ row, col - 1 }, vim.api.nvim_win_get_cursor(0))
        return
      end
    end
    error('Fixture does not contain ' .. marker)
  end

  local environments =
    'intro\n\\begin{document}\n\\begin{quote}outer\n\\begin{center}inner\\end{center}\n\\end{quote}\n\\begin{align*}x\\end{align*}\n\\end{document}\nlast'
  local env_markers = { '\\begin{document}', '\\begin{quote}', '\\begin{center}', '\\begin{align*}' }
  local formulas = 'intro\n$a$ 中文 \\(b\\)\n$$c$$\n\\[d\\]\n\\begin{align*}e + \\text{words $f$}\\end{align*}\nlast'
  local math_markers = { '$a$', '\\(b', '$$c$$', '\\[d', '\\begin{align*}', '$f$' }
  local cases = {
    {
      name = 'environment',
      fn = tex.jump_environment_start,
      source = environments,
      markers = env_markers,
      key = 'e',
      command = 'Environment',
    },
    { name = 'math', fn = tex.jump_math, source = formulas, markers = math_markers, key = 'm', command = 'Math' },
  }

  for _, case in ipairs(cases) do
    test(case.name .. ' navigation visits nested structures in source order and back', function()
      buffer(case.source)
      for _, marker in ipairs(case.markers) do
        eq(true, case.fn(1))
        cursor(marker)
      end
      at('last')
      for i = #case.markers, 1, -1 do
        eq(true, case.fn(-1))
        cursor(case.markers[i])
      end
      eq(case.source, content())
    end)

    test(case.name .. ' navigation supports counts, boundaries, and jump history', function()
      buffer(case.source)
      local origin = vim.api.nvim_win_get_cursor(0)
      keys('2]' .. case.key)
      cursor(case.markers[2])
      keys('<C-o>')
      eq(origin, vim.api.nvim_win_get_cursor(0))
      eq(true, case.fn(1, 100))
      cursor(case.markers[#case.markers])
      local before, jumps = vim.api.nvim_win_get_cursor(0), vim.fn.getjumplist()
      eq(false, case.fn(1))
      eq(before, vim.api.nvim_win_get_cursor(0))
      eq(jumps, vim.fn.getjumplist())
      keys('100[' .. case.key)
      cursor(case.markers[1])
      eq(false, case.fn(-1))
    end)

    test(case.name .. ' navigation commands accept count prefixes', function()
      buffer(case.source)
      vim.cmd('3TexToolsNext' .. case.command)
      cursor(case.markers[3])
      vim.cmd('2TexToolsPrevious' .. case.command)
      cursor(case.markers[1])
    end)

    test(case.name .. ' navigation reparses after edits and works in unmodifiable buffers', function()
      buffer('intro\n' .. (case.name == 'math' and '$old$' or '\\begin{quote}old\\end{quote}'))
      eq(true, case.fn(1))
      local target = case.name == 'math' and '\\[new\\]' or '\\begin{center}new\\end{center}'
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { '中文 ' .. target })
      at('intro')
      vim.bo.modifiable = false
      local ok = case.fn(1)
      vim.bo.modifiable = true
      eq(true, ok)
      cursor(target)
    end)

    test(case.name .. ' navigation opens folds at its destination', function()
      buffer(case.source)
      vim.wo.foldmethod = 'manual'
      vim.cmd('2,3fold')
      at('intro')
      eq(2, vim.fn.foldclosed(2))
      eq(true, case.fn(1))
      eq(-1, vim.fn.foldclosed(2))
      vim.cmd('normal! zE')
    end)

    test(case.name .. ' navigation reports parser loss and rejects invalid arguments', function()
      buffer(case.source)
      local before = vim.api.nvim_win_get_cursor(0)
      for _, direction in ipairs({ 0, 2, 'next', false }) do
        eq(false, case.fn(direction))
      end
      eq(false, case.fn(nil))
      for _, count in ipairs({ 0, -1, 1.5, math.huge, '2', false, 0 / 0 }) do
        eq(false, case.fn(1, count))
      end
      vim.treesitter.get_parser = function()
        error('missing parser')
      end
      local ok, err = case.fn(1)
      eq(false, ok)
      assert(err:find('parser unavailable', 1, true))
      eq(before, vim.api.nvim_win_get_cursor(0))
    end)
  end

  test('previous structure from its body returns to its own opening', function()
    buffer(environments)
    at('inner')
    eq(true, tex.jump_environment_start(-1))
    cursor('\\begin{center}')
    eq(true, tex.jump_environment_start(-1))
    cursor('\\begin{quote}')
    buffer('intro\n$outer + \\text{words $inner$}$\nlast')
    at('inner')
    eq(true, tex.jump_math(-1))
    cursor('$inner$')
    eq(true, tex.jump_math(-1))
    cursor('$outer')
  end)

  test('structure navigation skips comments, code environments, and definition bodies', function()
    local lines = {
      'intro',
      '% \\begin{quote}$hidden$\\end{quote}',
      '\\iffalse\n\\begin{quote}$hidden$\\end{quote}\n\\fi',
      '\\newcommand{\\hidden}{\\begin{quote}$hidden$\\end{quote}}',
      '\\newenvironment{hidden}{\\begin{quote}$hidden$\\end{quote}}{}',
    }
    for _, name in ipairs({ 'comment', 'verbatim', 'lstlisting', 'minted', 'luacode' }) do
      lines[#lines + 1] = '\\begin{' .. name .. '}' .. (name == 'minted' and '{lua}' or '')
      lines[#lines + 1] = '\\begin{quote}$hidden$\\end{quote}'
      lines[#lines + 1] = '\\end{' .. name .. '}'
    end
    lines[#lines + 1] = '\\begin{center}$visible$\\end{center}'
    buffer(table.concat(lines, '\n'))
    eq(true, tex.jump_environment_start(1))
    cursor('\\begin{center}')
    eq(false, tex.jump_environment_start(-1))
    at('intro')
    eq(true, tex.jump_math(1))
    cursor('$visible$')
    eq(false, tex.jump_math(-1))
  end)

  test('global structure navigation can leave comments and literal content', function()
    buffer('\\begin{verbatim}\nignored\n\\end{verbatim}\n% comment\n\\begin{quote}$visible$\\end{quote}')
    at('ignored')
    eq(true, tex.jump_environment_start(1))
    cursor('\\begin{quote}')
    at('comment')
    eq(true, tex.jump_math(1))
    cursor('$visible$')
  end)

  test('math navigation includes configured math environments and starred forms', function()
    tex.setup({ math_environments = { 'custom*' } })
    buffer('intro\n\\begin{quote}text\\end{quote}\n\\begin{custom}one\\end{custom}\n\\begin{custom*}two\\end{custom*}')
    eq(true, tex.jump_math(1))
    cursor('\\begin{custom}')
    eq(true, tex.jump_math(1))
    cursor('\\begin{custom*}')
    eq(false, tex.jump_math(1))
    tex.setup()
  end)

  test('environment navigation rejects mismatched markers but finds valid nested structures', function()
    buffer('intro\n\\begin{quote}\n\\begin{center}body\\end{center}\n\\end{wrong}\nlast')
    eq(true, tex.jump_environment_start(1))
    cursor('\\begin{center}')
    eq(false, tex.jump_environment_start(1))
    eq(false, tex.jump_environment_start(-1))
  end)

  test('environment body errors do not hide complete matching markers', function()
    buffer('intro\n\\begin{quote}\n}\n\\end{quote}\nlast')
    eq(true, tex.jump_environment_start(1))
    cursor('\\begin{quote}')
  end)

  test('empty environments and empty formulas remain navigation targets', function()
    buffer('intro\n\\begin{quote}\\end{quote}\n\\(\\)\n\\[\\]')
    eq(true, tex.jump_environment_start(1))
    cursor('\\begin{quote}')
    eq(true, tex.jump_math(1))
    cursor('\\(\\)')
    eq(true, tex.jump_math(1))
    cursor('\\[\\]')
  end)

  test('math navigation rejects every mismatched delimiter spelling', function()
    for _, expression in ipairs({ '$bad\\)', '\\(bad$', '$$bad\\]', '\\[bad$$' }) do
      buffer('intro\n' .. expression .. '\n\\(good\\)')
      eq(true, tex.jump_math(1))
      cursor('\\(good')
      eq(false, tex.jump_math(-1))
    end
  end)

  test('structure navigation preserves the preceding structural dot repeat', function()
    buffer('intro\n\\textbf{first}\n\\begin{quote}$\\textit{second}$\\end{quote}')
    at('first')
    eq(true, tex.rename_command('emph'))
    keys(']e]m')
    at('second')
    keys('.')
    eq('intro\n\\emph{first}\n\\begin{quote}$\\emph{second}$\\end{quote}', content())
  end)

  test('structure navigation skips incomplete environments and mismatched formula delimiters', function()
    buffer('intro\n\\(bad$\n\\[good\\]\n\\begin{quote}unfinished')
    eq(true, tex.jump_math(1))
    cursor('\\[good')
    eq(false, tex.jump_math(1))
    eq(false, tex.jump_math(-1))
    at('intro')
    eq(false, tex.jump_environment_start(1))
  end)

  test('structure navigation retains commands and Plug mappings with defaults disabled', function()
    tex.setup({ mappings = false })
    buffer(formulas, 'plaintex')
    for _, case in ipairs(cases) do
      for _, direction in ipairs({ { ']', 'Next' }, { '[', 'Previous' } }) do
        eq('', vim.fn.maparg(direction[1] .. case.key, 'n'))
        local name = direction[2] .. case.command
        assert(vim.fn.maparg('<Plug>(TexTools' .. name .. ')', 'n') ~= '')
        assert(vim.api.nvim_buf_get_commands(0, {})['TexTools' .. name])
      end
    end
    keys('<Plug>(TexToolsNextMath)')
    cursor('$a$')
    tex.setup()
  end)

  test('structure navigation preserves user mappings and the environment pair jump', function()
    buffer('intro', 'text')
    vim.keymap.set('n', ']e', 'GLOBAL')
    vim.keymap.set('n', '[m', 'LOCAL', { buffer = true })
    vim.bo.filetype = 'tex'
    tex.setup({ mappings = false })
    tex.setup()
    eq('GLOBAL', vim.fn.maparg(']e', 'n'))
    eq('LOCAL', vim.fn.maparg('[m', 'n'))
    vim.keymap.del('n', ']e')
    vim.keymap.del('n', '[m', { buffer = true })
    buffer('\\begin{quote}body\\end{quote}')
    at('body')
    keys(',lm')
    cursor('\\end{quote}')
    keys(',lm')
    cursor('\\begin{quote}')
  end)
end
