return function(h)
  local eq, buffer, at, content, keys = h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local function test(name, fn)
    h.test('item text objects: ' .. name, fn)
  end
  local function selected(inner, opts)
    local range, err = tex.textobject_range('item', inner, opts)
    assert(range, err)
    local sr, sc, er, ec = unpack(range)
    return table.concat(vim.api.nvim_buf_get_text(opts and opts.bufnr or 0, sr, sc, er, ec, {}), '\n')
  end
  local nested = table.concat({
    '\\begin{itemize}',
    '  \\item outer',
    '    continuation',
    '',
    '    second paragraph',
    '    \\begin{enumerate}',
    '      \\item inner 中文',
    '      \\item next inner',
    '    \\end{enumerate}',
    '    outer tail',
    '',
    '  \\item sibling',
    '\\end{itemize}',
  }, '\n')
  local outer_body = table.concat({
    'outer',
    '    continuation',
    '',
    '    second paragraph',
    '    \\begin{enumerate}',
    '      \\item inner 中文',
    '      \\item next inner',
    '    \\end{enumerate}',
    '    outer tail',
  }, '\n')

  for _, name in ipairs({ 'itemize', 'enumerate', 'description' }) do
    for _, marker in ipairs({ '\\item', '\\item[Label 中文]', '\\item*[Label]' }) do
      test(name .. ' preserves marker and label: ' .. marker, function()
        buffer('\\begin{' .. name .. '}\n  ' .. marker .. '  body 中文  \n  \\item sibling\n\\end{' .. name .. '}')
        at('body')
        eq('body 中文', selected(true))
        eq('  ' .. marker .. '  body 中文  \n', selected(false))
        at(marker)
        eq('body 中文', selected(true))
      end)
    end
  end

  test('multiline bodies include continuation paragraphs and nested lists', function()
    buffer(nested)
    for _, location in ipairs({ 'outer', 'continuation', 'second paragraph', 'outer tail' }) do
      at(location)
      eq(outer_body, selected(true))
      eq('  \\item ' .. outer_body .. '\n', selected(false))
    end
  end)

  test('default depth stays at the nearest list while counts select parent items', function()
    buffer(nested)
    at('inner 中文')
    eq('inner 中文', selected(true))
    eq('      \\item inner 中文\n', selected(false))
    eq(outer_body, selected(true, { count = 2 }))
    eq('  \\item ' .. outer_body .. '\n', selected(false, { count = 2 }))
    eq(nil, tex.textobject_range('item', false, { count = 3 }))
    at('sibling')
    eq(nil, tex.textobject_range('item', false, { count = 2 }))
  end)

  test('three levels count items rather than sibling markers', function()
    buffer(
      '\\begin{itemize}\\item one \\begin{enumerate}\\item two \\begin{description}\\item[Three] body\\end{description}\\end{enumerate}\\end{itemize}'
    )
    at('body')
    eq('body', selected(true))
    eq('two \\begin{description}\\item[Three] body\\end{description}', selected(true, { count = 2 }))
    eq(
      'one \\begin{enumerate}\\item two \\begin{description}\\item[Three] body\\end{description}\\end{enumerate}',
      selected(true, { count = 3 })
    )
  end)

  test('paragraph wrappers do not hide items or include the heading', function()
    buffer('\\begin{itemize}\n\\paragraph{Heading}\n  \\item first\n  \\item second\n\\end{itemize}')
    at('first')
    eq('  \\item first\n', selected(false))
    at('Heading')
    eq(nil, tex.textobject_range('item', false))
  end)

  test('blank separators belong to the previous item without expanding its range', function()
    buffer('\\begin{itemize}\n  \\item first\n\n  \\item second\n\\end{itemize}')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq('first', selected(true))
    eq('  \\item first\n', selected(false))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq('second', selected(true))
  end)

  test('trailing comments follow around items while standalone comments remain', function()
    buffer('\\begin{itemize}\n  \\item first % trailing\n  % standalone\n\n  \\item second\n\\end{itemize}')
    at('first')
    eq('first', selected(true))
    eq('  \\item first % trailing\n', selected(false))
    keys('dai')
    eq('\\begin{itemize}\n  % standalone\n\n  \\item second\n\\end{itemize}', content())
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(nil, tex.textobject_range('item', false))
  end)

  test('inner body keeps embedded comments and trims only surrounding whitespace', function()
    buffer('\\begin{itemize}\n  \\item\n    first % embedded\n    last 中文\n\\end{itemize}')
    at('last')
    eq('first % embedded\n    last 中文', selected(true))
  end)

  test('inner body preserves escaped trailing whitespace', function()
    buffer('\\begin{itemize}\n  \\item body\\ \n\\end{itemize}')
    at('body')
    eq('body\\ ', selected(true))
    keys('ciiNEW<Esc>')
    eq('\\begin{itemize}\n  \\item NEW\n\\end{itemize}', content())
  end)

  test('position columns past the line end are clamped without changing options', function()
    buffer('\\begin{itemize}\n  \\item body\n\\end{itemize}')
    local opts = { pos = { 1, 10000 } }
    eq('body', selected(true, opts))
    eq({ pos = { 1, 10000 } }, opts)
  end)

  test('inline items include following spaces without consuming neighboring syntax', function()
    buffer('\\begin{description}\\item[Label] first  \\item{second}\\end{description}')
    at('first')
    eq('\\item[Label] first  ', selected(false))
    eq('first', selected(true))
    keys('dai')
    eq('\\begin{description}\\item{second}\\end{description}', content())
    at('second')
    eq('{second}', selected(true))
    keys('dai')
    eq('\\begin{description}\\end{description}', content())
  end)

  for _, marker in ipairs({ '\\item', '\\item[Label]', '\\item*' }) do
    test('empty body refuses ii but permits ai: ' .. marker, function()
      buffer('\\begin{itemize}\n  ' .. marker .. '\n  \\item body\n\\end{itemize}')
      at(marker)
      eq(nil, tex.textobject_range('item', true))
      eq('  ' .. marker .. '\n', selected(false))
      keys('dai')
      eq('\\begin{itemize}\n  \\item body\n\\end{itemize}', content())
    end)
  end

  for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    test('real delete, change, yank and Visual operators with selection=' .. selection, function()
      vim.o.selection = selection
      buffer('\\begin{description}\n  \\item*[标签]  first 中文\n    last\n  \\item sibling\n\\end{description}')
      at('first')
      keys('yii')
      eq('first 中文\n    last', vim.fn.getreg('"'))
      at('first')
      keys('ciiNEW<Esc>')
      eq('\\begin{description}\n  \\item*[标签]  NEW\n  \\item sibling\n\\end{description}', content())
      keys('u')
      at('first')
      keys('vaiy')
      eq('  \\item*[标签]  first 中文\n    last\n', vim.fn.getreg('"'))
      at('first')
      keys('dai')
      eq('\\begin{description}\n  \\item sibling\n\\end{description}', content())
      at('sibling')
      keys('dai')
      eq('\\begin{description}\n\\end{description}', content())
    end)

    test('counted operators select the complete outer item with selection=' .. selection, function()
      vim.o.selection = selection
      buffer(nested)
      at('inner 中文')
      keys('y2ii')
      eq(outer_body, vim.fn.getreg('"'))
      at('inner 中文')
      keys('v2aiy')
      eq('  \\item ' .. outer_body .. '\n', vim.fn.getreg('"'))
      at('inner 中文')
      keys('d2ai')
      eq('\\begin{itemize}\n\n  \\item sibling\n\\end{itemize}', content())
    end)
  end

  test('native dot re-queries the item at the cursor and undo restores one deletion', function()
    local source = '\\begin{itemize}\n  \\item first\n  \\item second\n  \\item third\n\\end{itemize}'
    buffer(source)
    at('first')
    keys('dai')
    at('second')
    keys('.')
    eq('\\begin{itemize}\n  \\item third\n\\end{itemize}', content())
    keys('u')
    eq('\\begin{itemize}\n  \\item second\n  \\item third\n\\end{itemize}', content())
    keys('u')
    eq(source, content())
  end)

  test('change-body dot preserves each target label', function()
    buffer('\\begin{description}\n  \\item[One] first\n  \\item[Two] second\n\\end{description}')
    at('first')
    keys('ciiNEW<Esc>')
    at('second')
    keys('.')
    eq('\\begin{description}\n  \\item[One] NEW\n  \\item[Two] NEW\n\\end{description}', content())
  end)

  test('a count on dot replaces the previous item depth', function()
    buffer(
      '\\begin{itemize}\n  \\item first\n  \\item outer\n    \\begin{enumerate}\n      \\item inner\n    \\end{enumerate}\n\\end{itemize}'
    )
    at('first')
    keys('dai')
    at('inner')
    keys('2.')
    eq('\\begin{itemize}\n\\end{itemize}', content())
  end)

  test('a failed repeat outside a list leaves the buffer unchanged', function()
    buffer('outside\n\\begin{itemize}\n  \\item first\n\\end{itemize}')
    at('first')
    keys('dai')
    at('outside')
    vim.notify = function() end
    local before = content()
    keys('.')
    eq(before, content())
    eq('n', vim.fn.mode())
  end)

  test('failure cancels operators without an edit, register change or lost dot repeat', function()
    buffer('word\n\\begin{itemize}\n  \\item\n  \\item body\n\\end{itemize}')
    at('word')
    keys('ciwNEW<Esc>')
    at('\\item')
    local before, cursor, undo = content(), vim.api.nvim_win_get_cursor(0), vim.fn.undotree().seq_cur
    vim.fn.setreg('"', 'keep')
    vim.notify = function() end
    keys('cii')
    keys('d9ai')
    eq(before, content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
    eq(undo, vim.fn.undotree().seq_cur)
    eq('keep', vim.fn.getreg('"'))
    eq('n', vim.fn.mode())
    at('body')
    keys('.')
    eq(before:gsub('body', 'NEW'), content())
  end)

  local refused = {
    { 'plain text', 'plain' },
    { '\\begin{itemize}\n\\end{itemize}', 'itemize' },
    { '\\begin{itemize}\npreamble\n\\item body\n\\end{itemize}', 'preamble' },
    { '\\begin{itemize}\n\\item body\n\\end{itemize}', '\\begin' },
    { '\\begin{itemize}\n\\item body\n\\end{itemize}', '\\end' },
    { '\\begin{itemize}\n\\item body % ignored\n\\end{itemize}', 'ignored' },
    { '\\begin{itemize}\\item \\begin{quote}body\\end{quote}\\end{itemize}', 'body' },
    { '\\begin{itemize}\\item \\begin{verbatim}\nliteral\n\\end{verbatim}\\end{itemize}', 'literal' },
    { '\\newcommand{\\foo}{\\begin{itemize}\\item body\\end{itemize}}', 'body' },
    { '\\begin{itemize}\\item body\\end{enumerate}', 'body' },
    { '\\begin{itemize}\\item body', 'body' },
    { '\\begin{description}\\item[] body\\end{description}', 'body' },
  }
  for index, fixture in ipairs(refused) do
    test('unsafe or unavailable structure is refused: ' .. index, function()
      buffer(fixture[1])
      at(fixture[2])
      local cursor = vim.api.nvim_win_get_cursor(0)
      for _, inner in ipairs({ false, true }) do
        local range, err = tex.textobject_range('item', inner)
        eq(nil, range)
        assert(type(err) == 'string')
      end
      eq(fixture[1], content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  test('hidden-buffer range queries preserve options, cursor and current buffer', function()
    local bufnr = buffer('\\begin{description}\n  \\item[标签] 中文\n\\end{description}')
    buffer('elsewhere')
    local opts = { bufnr = bufnr, pos = { 1, #'  \\item[标签] ' } }
    local original, cursor = vim.deepcopy(opts), vim.api.nvim_win_get_cursor(0)
    eq('中文', selected(true, opts))
    eq('  \\item[标签] 中文\n', selected(false, opts))
    eq(original, opts)
    eq('elsewhere', content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
  end)

  test('selection API and unmodifiable-buffer yanks are supported', function()
    buffer(nested)
    at('inner 中文')
    vim.bo.modifiable = false
    eq(true, tex.select_textobject('item', true, 2))
    keys('y')
    local result = vim.fn.getreg('"')
    vim.bo.modifiable = true
    eq(outer_body, result)
  end)

  test('invalid counts and missing parsers return actionable errors', function()
    buffer(nested)
    at('inner 中文')
    for _, count in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, '2', false }) do
      local range, err = tex.textobject_range('item', false, { count = count })
      eq(nil, range)
      eq('Count must be a positive integer', err)
    end
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    local range, err = tex.textobject_range('item', false)
    eq(nil, range)
    assert(err:find('parser unavailable', 1, true))
  end)

  test('disabling defaults retains Plug mappings', function()
    tex.setup({ mappings = false })
    buffer('\\begin{itemize}\\item body\\end{itemize}')
    for _, mode in ipairs({ 'x', 'o' }) do
      eq('', vim.fn.maparg('ai', mode))
      eq('', vim.fn.maparg('ii', mode))
      assert(vim.fn.maparg('<Plug>(TexToolsAroundItem)', mode) ~= '')
      assert(vim.fn.maparg('<Plug>(TexToolsInsideItem)', mode) ~= '')
    end
    at('body')
    keys('y<Plug>(TexToolsInsideItem)')
    eq('body', vim.fn.getreg('"'))
    tex.setup()
  end)

  test('existing user mappings are preserved', function()
    buffer('\\begin{itemize}\\item body\\end{itemize}')
    vim.keymap.set({ 'x', 'o' }, 'ai', '<Nop>', { buffer = true })
    tex.setup()
    for _, mode in ipairs({ 'x', 'o' }) do
      eq('<Nop>', vim.fn.maparg('ai', mode))
    end
  end)
end
