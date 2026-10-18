return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function list_buffer(text)
    local bufnr = buffer(text)
    vim.bo.expandtab = true
    vim.bo.shiftwidth = 2
    vim.bo.autoindent = false
    vim.bo.indentexpr = ''
    vim.bo.formatoptions = ''
    vim.keymap.set('i', '<F6>', '<Plug>(TexToolsSmartEnter)', { buffer = true, remap = true })
    return bufnr
  end

  for _, name in ipairs({ 'itemize', 'enumerate', 'description' }) do
    test('smart Enter at the end of a ' .. name .. ' item', function()
      list_buffer('\\begin{' .. name .. '}\n  \\item first\n\\end{' .. name .. '}')
      at('first')
      keys('A<F6>NEW<Esc>')
      local item = name == 'description' and '\\item[NEW] ' or '\\item NEW'
      eq('\\begin{' .. name .. '}\n  \\item first\n  ' .. item .. '\n\\end{' .. name .. '}', content())
    end)
  end

  test('smart Enter splits at the cursor and keeps UTF-8 suffix text', function()
    list_buffer('\\begin{itemize}\n  \\item 中文 first second 中文\n\\end{itemize}')
    at('second')
    keys('i<F6>NEW <Esc>')
    eq('\\begin{itemize}\n  \\item 中文 first\n  \\item NEW second 中文\n\\end{itemize}', content())
  end)

  test('smart Enter trims adjacent whitespace without changing following lines', function()
    list_buffer('\\begin{enumerate}\n  \\item first   second\n    continuation\n  \\item next\n\\end{enumerate}')
    at('first', 5)
    keys('i<F6><Esc>')
    eq(
      '\\begin{enumerate}\n  \\item first\n  \\item second\n    continuation\n  \\item next\n\\end{enumerate}',
      content()
    )
  end)

  test('smart Enter in a description body focuses a fresh label', function()
    list_buffer('\\begin{description}\n  \\item[Old] first second\n\\end{description}')
    at('second')
    keys('i<F6>中文<Esc>')
    eq('\\begin{description}\n  \\item[Old] first\n  \\item[中文] second\n\\end{description}', content())
  end)

  test('smart Enter on a continuation line uses the item indentation', function()
    list_buffer('\\begin{itemize}\n\t\\item first\n\t    continuation rest\n\\end{itemize}')
    at('rest')
    keys('i<F6><Esc>')
    eq('\\begin{itemize}\n\t\\item first\n\t    continuation\n\t\\item rest\n\\end{itemize}', content())
  end)

  test('smart Enter stays at the nearest nested list level', function()
    list_buffer(
      '\\begin{itemize}\n  \\item outer\n    \\begin{enumerate}\n      \\item inner\n    \\end{enumerate}\n\\end{itemize}'
    )
    at('inner')
    keys('A<F6>NEW<Esc>')
    eq(
      '\\begin{itemize}\n  \\item outer\n    \\begin{enumerate}\n      \\item inner\n      \\item NEW\n    \\end{enumerate}\n\\end{itemize}',
      content()
    )
  end)

  test('smart Enter before a nested list moves it with the suffix', function()
    list_buffer(
      '\\begin{itemize}\n  \\item outer\n    \\begin{enumerate}\n      \\item inner\n    \\end{enumerate}\n\\end{itemize}'
    )
    at('outer')
    keys('A<F6>NEW<Esc>')
    eq(
      '\\begin{itemize}\n  \\item outer\n  \\item NEW\n    \\begin{enumerate}\n      \\item inner\n    \\end{enumerate}\n\\end{itemize}',
      content()
    )
  end)

  test('smart Enter can split an inline list body', function()
    list_buffer('\\begin{itemize}\\item first second\\end{itemize}')
    at('second')
    keys('i<F6>NEW <Esc>')
    eq('\\begin{itemize}\\item first\n  \\item NEW second\\end{itemize}', content())
  end)

  test('smart Enter at the beginning of body keeps the old marker separate', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys('i<F6><Esc>')
    eq('\\begin{itemize}\n  \\item \n  \\item first\n\\end{itemize}', content())
  end)

  for _, expression in ipairs({ '\\textbf{bold}', '$x$', '\\(x\\)', '\\%', '\\ ' }) do
    test('smart Enter after a complete structure: ' .. expression, function()
      list_buffer('\\begin{itemize}\n  \\item ' .. expression .. '\n\\end{itemize}')
      at(expression)
      keys('A<F6>NEW<Esc>')
      eq('\\begin{itemize}\n  \\item ' .. expression .. '\n  \\item NEW\n\\end{itemize}', content())
    end)
  end

  test('smart Enter preserves suffix comments', function()
    list_buffer('\\begin{itemize}\n  \\item first second % keep\n\\end{itemize}')
    at('second')
    keys('i<F6><Esc>')
    eq('\\begin{itemize}\n  \\item first\n  \\item second % keep\n\\end{itemize}', content())
  end)

  local ordinary = {
    { 'outside', 'outside', 3 },
    { '\\begin{itemize}\n  \\item \n\\end{itemize}', '\\item ', 6 },
    { '\\begin{description}\n  \\item[Label] \n\\end{description}', '\\item[Label] ', 13 },
    { '\\begin{itemize}\n\n\\end{itemize}', '', 0, 2 },
    { '\\begin{itemize}\n  \\item first % comment\n\\end{itemize}', 'comment', 3 },
    { '\\begin{itemize}\n  \\item first % comment\n\\end{itemize}', 'comment', 7 },
    { '\\begin{itemize}\n  \\item first\n  % comment\n\\end{itemize}', 'comment', 7 },
    { '\\begin{itemize}\n  \\item \\textbf{bold}\n\\end{itemize}', 'bold', 2 },
    { '\\begin{itemize}\n  \\item $formula$\n\\end{itemize}', 'formula', 3 },
    { '\\begin{description}\n  \\item[Label] first\n\\end{description}', 'Label', 2 },
    { '\\begin{itemize}\n  \\item first\n\\end{itemize}', '\\item', 3 },
    { '\\begin{itemize}\n  \\item first\n\\end{itemize}', 'begin', 2 },
    { '\\begin{itemize}\n  \\item first\n\\end{itemize}', 'end', 2 },
    { '\\begin{itemize}\n  \\item first', 'first', 5 },
    { '\\begin{itemize}\n  \\item first\n\\end{enumerate}', 'first', 5 },
    { '\\begin{quote}\n  \\item first\n\\end{quote}', 'first', 5 },
    { '\\begin{itemize}\n  \\item first\n  \\begin{verbatim}\ncode\n  \\end{verbatim}\n\\end{itemize}', 'code', 4 },
    { '\\begin{itemize}\n  \\item first\n  \\begin{minted}{lua}\ncode\n  \\end{minted}\n\\end{itemize}', 'code', 4 },
    { '\\begin{itemize}\n  \\item first\n  \\begin{quote}\nquoted\n  \\end{quote}\n\\end{itemize}', 'quoted', 3 },
    { '\\begin{itemize}\n  \\item first\n\n\\end{itemize}', '', 0, 3 },
  }
  for i, fixture in ipairs(ordinary) do
    test('smart Enter falls back to native Enter ' .. i, function()
      list_buffer(fixture[1])
      if fixture[4] then
        vim.api.nvim_win_set_cursor(0, { fixture[4], 0 })
      else
        at(fixture[2])
      end
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row, col = cursor[1], cursor[2] + fixture[3]
      local lines = vim.split(fixture[1], '\n', { plain = true })
      local original = lines[row]
      lines[row] = original:sub(1, col)
      table.insert(lines, row + 1, 'NEW' .. original:sub(col + 1))
      -- Enter Insert mode first so end-of-line byte positions remain valid.
      vim.keymap.set('i', '<F7>', function()
        vim.api.nvim_win_set_cursor(0, { row, col })
      end, { buffer = true })
      keys('i<F7><F6>NEW<Esc>')
      eq(table.concat(lines, '\n'), content())
    end)
  end

  test('smart Enter expression does not edit, move, or notify under textlock', function()
    list_buffer('\\begin{itemize}\n  \\item first second\n\\end{itemize}')
    at('second')
    local original, cursor = content(), vim.api.nvim_win_get_cursor(0)
    local notify = vim.notify
    vim.notify = function()
      error('unexpected notification')
    end
    assert(tex.smart_enter() ~= vim.keycode('<CR>'))
    eq(original, content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
    vim.notify = notify
  end)

  test('smart Enter with no parser falls back silently', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    vim.notify = function()
      error('unexpected notification')
    end
    keys('A<F6>NEW<Esc>')
    eq('\\begin{itemize}\n  \\item first\nNEW\n\\end{itemize}', content())
  end)

  test('smart Enter in an unmodifiable buffer leaves the buffer unchanged', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local original = content()
    vim.bo.modifiable = false
    keys('i<F6><Esc>')
    eq(original, content())
    vim.bo.modifiable = true
  end)

  test('smart Enter undo restores the split and preserves prior typing', function()
    list_buffer('\\begin{itemize}\n  \\item first second\n\\end{itemize}')
    at('second')
    keys('iPRE<F6>NEW<Esc>u')
    eq('\\begin{itemize}\n  \\item first PREsecond\n\\end{itemize}', content())
    keys('<C-r>')
    eq('\\begin{itemize}\n  \\item first PRE\n  \\item NEWsecond\n\\end{itemize}', content())
  end)

  test('repeated smart Enter creates successive siblings', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys('A<F6>second<F6>third<Esc>')
    eq('\\begin{itemize}\n  \\item first\n  \\item second\n  \\item third\n\\end{itemize}', content())
    keys('u')
    eq('\\begin{itemize}\n  \\item first\n  \\item second\n\\end{itemize}', content())
  end)

  test('Lua smart Enter composes with an expression mapping', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    vim.keymap.set('i', '<F8>', function()
      return tex.smart_enter()
    end, { buffer = true, expr = true, replace_keycodes = false })
    at('first')
    keys('A<F8>NEW<Esc>')
    eq('\\begin{itemize}\n  \\item first\n  \\item NEW\n\\end{itemize}', content())
  end)

  test('fallback Enter preserves native autoindent and comment continuation', function()
    list_buffer('  % comment')
    vim.bo.autoindent = true
    vim.bo.comments = 'b:%'
    vim.bo.formatoptions = 'r'
    keys('A<F6>NEW<Esc>')
    eq('  % comment\n  % NEW', content())
  end)

  test('description split and immediately typed label undo together', function()
    list_buffer('\\begin{description}\n  \\item[Old] first second\n\\end{description}')
    at('second')
    local original = content()
    keys('i<F6>中文<Esc>u')
    eq(original, content())
  end)

  test('smart Enter also works with undo disabled', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local levels = vim.bo.undolevels
    vim.bo.undolevels = -1
    keys('A<F6>NEW<Esc>')
    vim.bo.undolevels = levels
    eq('\\begin{itemize}\n  \\item first\n  \\item NEW\n\\end{itemize}', content())
  end)

  test('Enter is opt-in and repeated setup removes its own mapping', function()
    list_buffer('x')
    eq('', vim.fn.maparg('<CR>', 'i'))
    tex.setup({ smart_enter = true })
    eq('<Plug>(TexToolsSmartEnter)', vim.fn.maparg('<CR>', 'i'))
    tex.setup()
    eq('', vim.fn.maparg('<CR>', 'i'))
    assert(vim.fn.maparg('<Plug>(TexToolsSmartEnter)', 'i') ~= '')
  end)

  test('disabled mappings do not install Enter even with smart_enter enabled', function()
    tex.setup({ mappings = false, smart_enter = true })
    list_buffer('x')
    eq('', vim.fn.maparg('<CR>', 'i'))
    assert(vim.fn.maparg('<Plug>(TexToolsSmartEnter)', 'i') ~= '')
    tex.setup()
  end)

  test('opt-in Enter works in real Insert mode', function()
    tex.setup({ smart_enter = true })
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys('A<CR>NEW<Esc>')
    eq('\\begin{itemize}\n  \\item first\n  \\item NEW\n\\end{itemize}', content())
    list_buffer('outside')
    keys('A<CR>NEW<Esc>')
    eq('outside\nNEW', content())
    tex.setup()
  end)

  test('opt-in Enter preserves global and buffer-local user mappings', function()
    vim.keymap.set('i', '<CR>', 'GLOBAL')
    tex.setup({ smart_enter = true })
    list_buffer('x')
    eq('GLOBAL', vim.fn.maparg('<CR>', 'i'))
    vim.keymap.del('i', '<CR>')
    vim.keymap.set('i', '<CR>', 'LOCAL', { buffer = true })
    tex.setup()
    tex.setup({ smart_enter = true })
    eq('LOCAL', vim.fn.maparg('<CR>', 'i'))
    vim.keymap.del('i', '<CR>', { buffer = true })
    tex.setup()
  end)
end
