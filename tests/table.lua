return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local source = [=[\begin{tabular}{lc}
  中文 & {b & c} \\[2pt]
  d & e \\
\end{tabular}]=]
  test('table cells skip nested separators and row spacing with native operators', function()
    buffer(source)
    at('中文')
    keys('yit')
    eq('中文', vim.fn.getreg('"'))
    eq(true, tex.jump_cell(1))
    keys('yit')
    eq('{b & c}', vim.fn.getreg('"'))
    eq(true, tex.jump_cell(1))
    keys('yit')
    eq('d', vim.fn.getreg('"'))
    eq(true, tex.jump_cell(-1, 2))
    eq(source, content())
    local before = vim.api.nvim_win_get_cursor(0)
    eq(false, tex.jump_cell(-1))
    eq(before, vim.api.nvim_win_get_cursor(0))
    at('lc')
    eq(false, tex.jump_cell(1))
  end)
  test('table row insert and delete preserve content and one-step undo', function()
    buffer(source)
    at('中文')
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.table_edit('insert_row'))
    eq(5, vim.api.nvim_buf_line_count(0))
    vim.cmd.undo()
    eq(source, content())
    at('d & e')
    eq(true, tex.table_edit('delete_row'))
    eq(false, content():find('d & e', 1, true) ~= nil)
  end)
  test('table columns update the preamble and preserve row break options', function()
    buffer(source)
    at('中文')
    eq(true, tex.table_edit('insert_column'))
    eq(true, content():find('{llc}', 1, true) ~= nil)
    eq(true, content():find('中文 &  & {b & c} \\\\[2pt]', 1, true) ~= nil)
    at('{b & c}')
    eq(true, tex.table_edit('delete_column'))
    eq(true, content():find('{ll}', 1, true) ~= nil)
    eq(false, content():find('{b & c}', 1, true) ~= nil)
  end)
  test('matrix row insertion terminates an unterminated last row', function()
    buffer([=[\begin{pmatrix}
a & b
\end{pmatrix}]=])
    at('a & b')
    eq(true, tex.table_edit('insert_row'))
    eq(true, content():find('a & b \\\\', 1, true) ~= nil)
    at('a & b')
    eq(true, tex.table_edit('delete_column'))
    eq(true, content():find('b \\\\', 1, true) ~= nil)
  end)
  for _, body in ipairs({
    'a & b \\\\\n% keep\nc & d \\\\',
    'a & \\multicolumn{2}{c}{b} \\\\',
    'a & b \\\\\nc & d & e \\\\',
    '\\hline\na & b \\\\',
    'a & b \\\\ c & d \\\\',
    'a & \\begin{matrix}b\\end{matrix} \\\\',
  }) do
    test('unsafe table edits leave source intact: ' .. body, function()
      buffer('\\begin{tabular}{cc}\n' .. body .. '\n\\end{tabular}')
      at('a &')
      local original = content()
      eq(false, tex.table_edit('insert_row'))
      eq(original, content())
    end)
  end
  test('complex preambles refuse column edits; unmodifiable buffers refuse edits', function()
    buffer('\\begin{tabular}{|p{2cm}|c|}\na & b \\\\\n\\end{tabular}')
    at('a &')
    eq(false, tex.table_edit('insert_column'))
    vim.bo.modifiable = false
    eq(false, tex.table_edit('insert_row'))
    vim.bo.modifiable = true
  end)
  test('empty cells remain navigable and align cells support objects and rows', function()
    buffer([=[\begin{align}
a &  & b \\
c & d & e \\
\end{align}]=])
    at('a &')
    eq(true, tex.jump_cell(1))
    eq(nil, tex.textobject_range('cell', true))
    eq(true, tex.jump_cell(1))
    keys('yit')
    eq('b', vim.fn.getreg('"'))
    eq(false, tex.table_edit('insert_column'))
    eq(true, tex.table_edit('insert_row'))
  end)
  test('nearest unsupported environment stops cell lookup', function()
    buffer('\\begin{tabular}{c}\\begin{quote}body\\end{quote}\\end{tabular}')
    at('body')
    eq(nil, tex.textobject_range('cell', true))
  end)
end
