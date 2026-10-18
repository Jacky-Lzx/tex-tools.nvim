return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function list_buffer(text)
    local bufnr = buffer(text)
    vim.bo.expandtab = true
    vim.bo.shiftwidth = 2
    vim.bo.tabstop = 8
    return bufnr
  end

  local function insert()
    local ok, err = tex.insert_item()
    vim.cmd.stopinsert()
    return ok, err
  end

  for _, name in ipairs({ 'itemize', 'enumerate', 'description' }) do
    test('insert a sibling in ' .. name, function()
      list_buffer('\\begin{' .. name .. '}\n  \\item first\n  \\item second\n\\end{' .. name .. '}')
      at('first')
      eq(true, insert())
      local marker = name == 'description' and '\\item[] ' or '\\item '
      eq(
        '\\begin{' .. name .. '}\n  \\item first\n  ' .. marker .. '\n  \\item second\n\\end{' .. name .. '}',
        content()
      )
      eq({ 3, 8 }, vim.api.nvim_win_get_cursor(0))
    end)
  end

  test('insert after the entire multiline item', function()
    list_buffer(
      '\\begin{itemize}\n  \\item first\n    中文 continuation\n\n    last paragraph\n  \\item second\n\\end{itemize}'
    )
    at('first')
    eq(true, insert())
    eq(
      '\\begin{itemize}\n  \\item first\n    中文 continuation\n\n    last paragraph\n  \\item \n  \\item second\n\\end{itemize}',
      content()
    )
  end)

  test('insert from a continuation line without copying its indentation', function()
    list_buffer('\\begin{enumerate}\n   \\item first\n       continuation\n\\end{enumerate}')
    at('continuation')
    eq(true, insert())
    eq('\\begin{enumerate}\n   \\item first\n       continuation\n   \\item \n\\end{enumerate}', content())
  end)

  local nested =
    '\\begin{itemize}\n  \\item outer\n    \\begin{enumerate}\n      \\item inner one\n      \\item inner two\n    \\end{enumerate}\n    outer continuation\n  \\item outer second\n\\end{itemize}'
  test('nested list insertion stays at the inner level', function()
    list_buffer(nested)
    at('inner one')
    eq(true, insert())
    eq(nested:gsub('      \\item inner two', '      \\item \n      \\item inner two'), content())
  end)

  test('outer item insertion follows its nested list and continuation', function()
    list_buffer(nested)
    at('item outer', 5)
    eq(true, insert())
    eq(nested:gsub('  \\item outer second', '  \\item \n  \\item outer second'), content())
  end)

  test('inserting after the last nested item stays before the inner end', function()
    list_buffer(nested)
    at('inner two')
    eq(true, insert())
    eq(nested:gsub('    \\end{enumerate}', '      \\item \n    \\end{enumerate}'), content())
  end)

  test('trailing comments remain attached to their original line', function()
    list_buffer('\\begin{itemize}\n  \\item first % keep this\n  % standalone comment\n\n\\end{itemize}')
    at('first')
    eq(true, insert())
    eq('\\begin{itemize}\n  \\item first % keep this\n  \\item \n  % standalone comment\n\n\\end{itemize}', content())
  end)

  test('blank gaps use the preceding item', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\n  \\item second\n\\end{itemize}')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(true, insert())
    eq('\\begin{itemize}\n  \\item first\n  \\item \n\n  \\item second\n\\end{itemize}', content())
  end)

  test('same-line item and end markers are split without losing text', function()
    list_buffer('\\begin{itemize}\\item 中文\\item second\\end{itemize}')
    at('中文')
    eq(true, insert())
    eq('\\begin{itemize}\\item 中文\n  \\item \n  \\item second\\end{itemize}', content())
  end)

  test('last inline item remains inside the list', function()
    list_buffer('prefix \\begin{itemize}\\item 中文\\end{itemize} suffix')
    at('中文')
    eq(true, insert())
    eq('prefix \\begin{itemize}\\item 中文\n  \\item \n\\end{itemize} suffix', content())
  end)

  test('explicit item labels and stars are not copied', function()
    list_buffer('\\begin{enumerate}[label=\\alph*)]\n  \\item*[Custom] first\n\\end{enumerate}')
    at('first')
    eq(true, insert())
    eq('\\begin{enumerate}[label=\\alph*)]\n  \\item*[Custom] first\n  \\item \n\\end{enumerate}', content())
  end)

  test('description inserts an empty label rather than copying the old label', function()
    list_buffer('\\begin{description}\n  \\item[中文] definition\n\\end{description}')
    at('definition')
    eq(true, insert())
    eq('\\begin{description}\n  \\item[中文] definition\n  \\item[] \n\\end{description}', content())
    eq({ 3, 8 }, vim.api.nvim_win_get_cursor(0))
  end)

  test('empty list can receive its first item', function()
    list_buffer('  \\begin{itemize}\n\n  \\end{itemize}')
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(true, insert())
    eq('  \\begin{itemize}\n\n    \\item \n  \\end{itemize}', content())
  end)

  test('empty nested description gets its own label and indentation', function()
    list_buffer('\\begin{itemize}\n  \\item outer\n    \\begin{description}\n\n    \\end{description}\n\\end{itemize}')
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq(true, insert())
    eq(
      '\\begin{itemize}\n  \\item outer\n    \\begin{description}\n\n      \\item[] \n    \\end{description}\n\\end{itemize}',
      content()
    )
  end)

  test('existing tab indentation is preserved exactly', function()
    list_buffer('\\begin{itemize}\n\t\\item first\n\\end{itemize}')
    at('first')
    eq(true, insert())
    eq('\\begin{itemize}\n\t\\item first\n\t\\item \n\\end{itemize}', content())
  end)

  test('empty-list indentation honors tabstop and shiftwidth', function()
    list_buffer('\t\\begin{itemize}\n\n\t\\end{itemize}')
    vim.bo.expandtab = false
    vim.bo.shiftwidth = 6
    vim.bo.tabstop = 4
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(true, insert())
    eq('\t\\begin{itemize}\n\n\t\t  \\item \n\t\\end{itemize}', content())
  end)

  test('shiftwidth zero uses tabstop for empty-list indentation', function()
    list_buffer('\\begin{itemize}\n\n\\end{itemize}')
    vim.bo.shiftwidth = 0
    vim.bo.tabstop = 4
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(true, insert())
    eq('\\begin{itemize}\n\n    \\item \n\\end{itemize}', content())
  end)

  test('normal mapping enters Insert mode at the new item body', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys(',li中文 body<Esc>')
    eq('\\begin{itemize}\n  \\item first\n  \\item 中文 body\n\\end{itemize}', content())
  end)

  test('normal description mapping types inside the new label', function()
    list_buffer('\\begin{description}\n  \\item[Old] first\n\\end{description}')
    at('first')
    keys(',li中文<Esc>')
    eq('\\begin{description}\n  \\item[Old] first\n  \\item[中文] \n\\end{description}', content())
  end)

  test('Insert-mode mapping appends after the entire current item', function()
    list_buffer('\\begin{enumerate}\n  \\item first\n    continuation\n\\end{enumerate}')
    at('first')
    keys('i,liNEW<Esc>')
    eq('\\begin{enumerate}\n  \\item first\n    continuation\n  \\item NEW\n\\end{enumerate}', content())
  end)

  test('Insert-mode description mapping places typing inside the label', function()
    list_buffer('\\begin{description}\n  \\item[Old] first\n\\end{description}')
    at('first')
    keys('i,liNEW<Esc>')
    eq('\\begin{description}\n  \\item[Old] first\n  \\item[NEW] \n\\end{description}', content())
  end)

  test('a failed Insert-mode mapping keeps typing at the original position', function()
    list_buffer('outside')
    at('outside')
    keys('i,liNEW<Esc>')
    eq('NEWoutside', content())
  end)

  test('undo after using the mapping removes the new item and its typed body', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    keys(',liNEW<Esc>u')
    eq(original, content())
  end)

  test('undo preserves text typed in the preceding item before Insert-mode insertion', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    vim.cmd('let &undolevels = &undolevels')
    keys('iPRE,liNEW<Esc>u')
    eq('\\begin{itemize}\n  \\item PREfirst\n\\end{itemize}', content())
  end)

  test('leaving Insert mode without typing does not join a later edit', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys(',li<Esc>ggA unrelated<Esc>u')
    eq('\\begin{itemize}\n  \\item first\n  \\item \n\\end{itemize}', content())
    eq(0, #vim.api.nvim_get_autocmds({ group = 'TexToolsListUndo', buffer = 0 }))
  end)

  test('cursor movement before typing does not join an unrelated edit', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys(',li<Up>X<Esc>u')
    eq('\\begin{itemize}\n  \\item first\n  \\item \n\\end{itemize}', content())
  end)

  test('insertion also works with undo disabled', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local levels = vim.bo.undolevels
    vim.bo.undolevels = -1
    keys(',liNEW<Esc>')
    vim.bo.undolevels = levels
    eq('\\begin{itemize}\n  \\item first\n  \\item NEW\n\\end{itemize}', content())
  end)

  test('buffer command inserts a list item', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    vim.cmd.TexToolsInsertItem()
    vim.cmd.stopinsert()
    eq('\\begin{itemize}\n  \\item first\n  \\item \n\\end{itemize}', content())
  end)

  test('one undo removes a newly inserted item', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    eq(true, insert())
    vim.cmd.undo()
    eq(original, content())
  end)

  test('one undo restores inline item layout', function()
    list_buffer('\\begin{itemize}\\item first\\end{itemize}')
    at('first')
    local original = content()
    vim.cmd('let &undolevels = &undolevels')
    eq(true, insert())
    vim.cmd.undo()
    eq(original, content())
  end)

  local refused = {
    { 'ordinary text', 'ordinary' },
    { '\\item outside a list', 'outside' },
    { '\\begin{quote}\n\\item first\n\\end{quote}', 'first' },
    { '\\begin{itemize}\n  \\item outer\n  \\begin{quote}\n    quoted\n  \\end{quote}\n\\end{itemize}', 'quoted' },
    { '\\begin{itemize}\n  \\item first % ignored\n\\end{itemize}', 'ignored' },
    { '\\begin{itemize}\n  \\item first\n  % standalone\n\\end{itemize}', 'standalone' },
    { '\\begin{itemize}\n  \\item first\n  \\iffalse\n  ignored\n  \\fi\n\\end{itemize}', 'ignored' },
    {
      '\\begin{itemize}\n  \\item first\n  \\begin{verbatim}\n  ignored\n  \\end{verbatim}\n\\end{itemize}',
      'ignored',
    },
    {
      '\\begin{itemize}\n  \\item first\n  \\begin{minted}{lua}\n  ignored\n  \\end{minted}\n\\end{itemize}',
      'ignored',
    },
    { '\\begin{itemize}\n  \\item first\n\\end{enumerate}', 'first' },
    { '\\begin{itemize}\n  \\item first', 'first' },
    { '\\begin{itemize}\n  \\item[unfinished\n\\end{itemize}', 'unfinished' },
    { '\\begin{itemize}\n  \\item first\n\\end{itemize}', 'begin' },
    { '\\begin{itemize}\n  \\item first\n\\end{itemize}', 'end' },
  }
  for i, fixture in ipairs(refused) do
    test('refuse invalid list context ' .. i, function()
      list_buffer(fixture[1])
      at(fixture[2])
      local cursor = vim.api.nvim_win_get_cursor(0)
      local ok, err = insert()
      eq(false, ok)
      assert(type(err) == 'string' and err ~= '')
      eq(fixture[1], content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  test('before the first item does not choose an item in the outer list', function()
    list_buffer(
      '\\begin{itemize}\n  \\item outer\n  \\begin{enumerate}\n\n    \\item first\n  \\end{enumerate}\n\\end{itemize}'
    )
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local original = content()
    eq(false, insert())
    eq(original, content())
  end)

  test('unmodifiable list is unchanged', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local original = content()
    vim.bo.modifiable = false
    local ok = insert()
    vim.bo.modifiable = true
    eq(false, ok)
    eq(original, content())
  end)

  test('missing parser reports failure without editing', function()
    list_buffer('\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    local get_parser = vim.treesitter.get_parser
    vim.treesitter.get_parser = function()
      error('parser unavailable')
    end
    local ok, err = insert()
    vim.treesitter.get_parser = get_parser
    eq(false, ok)
    assert(err:find('parser unavailable', 1, true))
  end)

  test('disabled defaults retain the command and both Plug mappings', function()
    tex.setup({ mappings = false })
    list_buffer('x')
    assert(vim.api.nvim_buf_get_commands(0, {}).TexToolsInsertItem)
    eq('', vim.fn.maparg(',li', 'n'))
    eq('', vim.fn.maparg(',li', 'i'))
    assert(vim.fn.maparg('<Plug>(TexToolsInsertItem)', 'n') ~= '')
    assert(vim.fn.maparg('<Plug>(TexToolsInsertItem)', 'i') ~= '')
    tex.setup()
  end)

  test('existing Insert-mode user mapping is preserved', function()
    buffer('x', 'text')
    vim.keymap.set('i', ',li', 'USER', { buffer = true })
    vim.bo.filetype = 'tex'
    eq('USER', vim.fn.maparg(',li', 'i'))
  end)
end
