return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function position(text, offset)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      local col = line:find(text, 1, true)
      if col then
        return { row, col - 1 + (offset or 0) }
      end
    end
    error('Fixture does not contain ' .. text)
  end

  local function cursor(text)
    eq(position(text), vim.api.nvim_win_get_cursor(0))
  end

  local headings = {
    '\\part{Part}',
    '\\chapter*[Short]{章}',
    '\\section{One}',
    '\\subsection*{Sub}',
    '\\subsubsection{Deep}',
    '\\paragraph{Para}',
    '\\subparagraph*{Small}',
    '\\section{Last}',
  }
  local sections = 'intro\n' .. table.concat(headings, '\nbody\n') .. '\nlast body'

  test('visit all section levels in source order and back', function()
    buffer(sections)
    for _, heading in ipairs(headings) do
      eq(true, tex.jump_section(1))
      cursor(heading)
    end
    at('last body')
    for i = #headings, 1, -1 do
      eq(true, tex.jump_section(-1))
      cursor(headings[i])
    end
    eq(sections, content())
  end)

  test('section count and oversized counts stop at available targets', function()
    buffer(sections)
    eq(true, tex.jump_section(1, 3))
    cursor(headings[3])
    eq(true, tex.jump_section(1, 100))
    cursor(headings[#headings])
    eq(true, tex.jump_section(-1, 3))
    cursor(headings[#headings - 3])
    eq(true, tex.jump_section(-1, 100))
    cursor(headings[1])
  end)

  test('previous section from its body or title returns to its own marker', function()
    buffer(sections)
    at('last body')
    eq(true, tex.jump_section(-1))
    cursor('\\section{Last}')
    at('Last')
    eq(true, tex.jump_section(-1))
    cursor('\\section{Last}')
  end)

  test('section targets include starred forms and KOMA aliases', function()
    local commands = {
      'part*',
      'chapter',
      'section*',
      'subsection',
      'subsubsection*',
      'paragraph*',
      'subparagraph',
      'addpart',
      'addpart*',
      'addchap',
      'addchap*',
      'addsec',
      'addsec*',
    }
    local lines = { 'intro' }
    for _, command in ipairs(commands) do
      lines[#lines + 1] = '\\' .. command .. '{Title}'
    end
    buffer(table.concat(lines, '\n'))
    for i, command in ipairs(commands) do
      eq(true, tex.jump_section(1))
      eq({ i + 1, 0 }, vim.api.nvim_win_get_cursor(0))
      eq('\\' .. command .. '{Title}', vim.api.nvim_get_current_line())
    end
  end)

  test('same-line section targets use byte columns after UTF-8 text', function()
    buffer('intro \\section{First} 中文 \\section*{Second}')
    eq(true, tex.jump_section(1, 2))
    cursor('\\section*')
    eq(true, tex.jump_section(-1))
    cursor('\\section{First}')
  end)

  test('section traversal skips comments, literal environments, and definitions', function()
    local lines = {
      'intro',
      '% \\section{Line comment}',
      '\\iffalse',
      '\\section{Block comment}',
      '\\fi',
      '\\newcommand{\\hidden}{\\section{Macro body}}',
      '\\newenvironment{hidden}{\\section{Environment definition}}{}',
    }
    for _, name in ipairs({ 'comment', 'verbatim', 'lstlisting', 'minted', 'luacode' }) do
      lines[#lines + 1] = '\\begin{' .. name .. '}' .. (name == 'minted' and '{lua}' or '')
      lines[#lines + 1] = '\\section{Hidden}'
      lines[#lines + 1] = '\\end{' .. name .. '}'
    end
    lines[#lines + 1] = '\\section{Visible}'
    buffer(table.concat(lines, '\n'))
    eq(true, tex.jump_section(1))
    cursor('\\section{Visible}')
    eq(false, tex.jump_section(-1))
  end)

  test('sections inside a document environment are reachable from comments', function()
    buffer('\\begin{document}\n% comment\n\\section{First}\n\\end{document}')
    at('comment')
    eq(true, tex.jump_section(1))
    cursor('\\section')
  end)

  test('incomplete section headers are skipped without rejecting valid body headings', function()
    buffer('intro\n\\section\nbody\n\\section{Valid}\n\\textbf{unfinished')
    eq(true, tex.jump_section(1))
    cursor('\\section{Valid}')
    eq(false, tex.jump_section(-1))
  end)

  test('a complete heading recovered under an error node remains reachable', function()
    buffer('intro\n\\section{unfinished\n\\section{Valid}\nbody')
    eq(true, tex.jump_section(1))
    cursor('\\section{Valid}')
  end)

  test('navigation reparses the current buffer after edits', function()
    buffer('intro\n\\section{Old}')
    eq(true, tex.jump_section(1))
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { '\\subsection{New}' })
    at('intro')
    eq(true, tex.jump_section(1))
    cursor('\\subsection{New}')
  end)

  local nested =
    '\\begin{itemize}\n  \\item outer one\n    continuation\n    \\begin{enumerate}\n      \\item inner one\n      \\item inner two\n    \\end{enumerate}\n    outer continuation\n  \\item outer two\n  \\item outer three\n\\end{itemize}'

  test('outer item navigation skips nested items', function()
    buffer(nested)
    at('\\item outer one')
    eq(true, tex.jump_item(1))
    cursor('\\item outer two')
    eq(true, tex.jump_item(1))
    cursor('\\item outer three')
    eq(true, tex.jump_item(-1, 2))
    cursor('\\item outer one')
    eq(nested, content())
  end)

  test('inner item navigation stays within the inner list at both boundaries', function()
    buffer(nested)
    at('\\item inner one')
    eq(false, tex.jump_item(-1))
    eq(true, tex.jump_item(1, 100))
    cursor('\\item inner two')
    eq(false, tex.jump_item(1))
    eq(true, tex.jump_item(-1, 100))
    cursor('\\item inner one')
  end)

  test('continuation lines after a nested list use the outer scope', function()
    buffer(nested)
    at('outer continuation')
    eq(true, tex.jump_item(1))
    cursor('\\item outer two')
    at('outer continuation')
    eq(true, tex.jump_item(-1))
    cursor('\\item outer one')
  end)

  for _, name in ipairs({ 'itemize', 'enumerate', 'description' }) do
    test('item navigation supports labels, stars, and empty items in ' .. name, function()
      buffer('\\begin{' .. name .. '}\n  \\item[First] one\n  \\item* two\n  \\item\n\\end{' .. name .. '}')
      eq(true, tex.jump_item(1))
      cursor('\\item[First]')
      eq(true, tex.jump_item(1))
      cursor('\\item*')
      eq(true, tex.jump_item(1))
      eq({ 4, 2 }, vim.api.nvim_win_get_cursor(0))
      at('\\end')
      eq(true, tex.jump_item(-1, 3))
      cursor('\\item[First]')
    end)
  end

  test('same-line item navigation handles UTF-8 byte columns', function()
    buffer('\\begin{itemize}\\item 中文 \\item 二\\end{itemize}')
    eq(true, tex.jump_item(1, 2))
    cursor('\\item 二')
    eq(true, tex.jump_item(-1))
    cursor('\\item 中文')
  end)

  test('item scope crosses structural paragraph wrappers', function()
    buffer('\\begin{itemize}\n\\paragraph{Label}\n\\item one\n\\item two\n\\end{itemize}')
    eq(true, tex.jump_item(1, 2))
    cursor('\\item two')
    eq(true, tex.jump_item(-1))
    cursor('\\item one')
  end)

  test('item navigation can start inside a label declaration', function()
    buffer('\\begin{enumerate}\n\\item first \\label{itm:first}\n\\item second\n\\end{enumerate}')
    at('itm:first')
    eq(true, tex.jump_item(1))
    cursor('\\item second')
  end)

  test('item navigation skips commented, literal, and definition targets', function()
    buffer(
      '\\begin{itemize}\n\\item first\n% \\item commented\n\\iffalse\n\\item block\n\\fi\n\\begin{verbatim}\n\\item code\n\\end{verbatim}\n\\newcommand{\\hidden}{\\item definition}\n\\item last\n\\end{itemize}'
    )
    at('\\item first')
    eq(true, tex.jump_item(1))
    cursor('\\item last')
    eq(true, tex.jump_item(-1))
    cursor('\\item first')
  end)

  local invalid_lists = {
    { 'ordinary text', 'ordinary' },
    { '\\item outside', 'outside' },
    { '\\begin{quote}\n\\item quoted\n\\end{quote}', 'quoted' },
    { '\\begin{itemize}\n\\item one\n\\end{enumerate}', 'one' },
    { '\\begin{itemize}\n\\item one', 'one' },
    { '\\begin{itemize}\n% comment\n\\item one\n\\end{itemize}', 'comment' },
    { '\\begin{itemize}\n\\item one\n\\begin{verbatim}\ncode\n\\end{verbatim}\n\\end{itemize}', 'code' },
    { '\\begin{itemize}\n\\item one\n\\begin{quote}\nquoted\n\\end{quote}\n\\end{itemize}', 'quoted' },
    { '\\newcommand{\\hidden}{\\begin{itemize}\\item macro\\end{itemize}}', 'macro' },
  }
  for i, fixture in ipairs(invalid_lists) do
    test('invalid list scope does not move or edit ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      local original = vim.api.nvim_win_get_cursor(0)
      local ok, err = tex.jump_item(1)
      eq(false, ok)
      assert(type(err) == 'string')
      eq(original, vim.api.nvim_win_get_cursor(0))
      eq(fixture[1], content())
    end)
  end

  test('empty lists have no navigation targets', function()
    buffer('\\begin{itemize}\n\n\\end{itemize}')
    eq(false, tex.jump_item(1))
    eq(false, tex.jump_item(-1))
  end)

  test('navigation failures preserve the cursor, previous-context mark, and jumplist', function()
    buffer('intro\n\\section{Only}')
    at('\\section')
    local original, previous, jumps = vim.api.nvim_win_get_cursor(0), vim.fn.getpos("''"), vim.fn.getjumplist()
    eq(false, tex.jump_section(1))
    eq(false, tex.jump_section(-1))
    eq(original, vim.api.nvim_win_get_cursor(0))
    eq(previous, vim.fn.getpos("''"))
    eq(jumps, vim.fn.getjumplist())
  end)

  test('successful section and item jumps can return through Ctrl-O', function()
    buffer('intro\n\\section{First}\n\\section{Second}')
    vim.cmd.clearjumps()
    local origin = vim.api.nvim_win_get_cursor(0)
    keys('2]]')
    cursor('\\section{Second}')
    keys('<C-o>')
    eq(origin, vim.api.nvim_win_get_cursor(0))
    buffer(nested)
    at('outer continuation')
    vim.cmd.clearjumps()
    origin = vim.api.nvim_win_get_cursor(0)
    keys(']i')
    cursor('\\item outer two')
    keys('<C-o>')
    eq(origin, vim.api.nvim_win_get_cursor(0))
  end)

  test('counted Normal mappings work in both directions', function()
    buffer(sections)
    keys('3]]')
    cursor(headings[3])
    keys('2[[')
    cursor(headings[1])
    buffer(nested)
    keys('3]i')
    cursor('\\item outer three')
    keys('2[i')
    cursor('\\item outer one')
  end)

  test('navigation commands accept counts and choose their direction and scope', function()
    buffer(sections)
    vim.cmd('3TexToolsNextSection')
    cursor(headings[3])
    vim.cmd('2TexToolsPreviousSection')
    cursor(headings[1])
    buffer(nested)
    vim.cmd('3TexToolsNextItem')
    cursor('\\item outer three')
    vim.cmd('2TexToolsPreviousItem')
    cursor('\\item outer one')
  end)

  test('navigation opens folds containing its destination', function()
    buffer('intro\n\\section{Folded}\nbody\n\\section{Last}')
    vim.wo.foldmethod = 'manual'
    vim.cmd('2,3fold')
    at('intro')
    eq(2, vim.fn.foldclosed(2))
    eq(true, tex.jump_section(1))
    cursor('\\section{Folded}')
    eq(-1, vim.fn.foldclosed(2))
    vim.cmd('normal! zE')
  end)

  test('navigation does not require modifiable buffers', function()
    buffer('\\begin{itemize}\n\\item one\n\\item two\n\\end{itemize}\n\\section{Last}')
    vim.bo.modifiable = false
    local item_ok = tex.jump_item(1, 2)
    cursor('\\item two')
    local section_ok = tex.jump_section(1)
    cursor('\\section{Last}')
    vim.bo.modifiable = true
    eq(true, item_ok)
    eq(true, section_ok)
  end)

  test('missing parser reports navigation failure without moving', function()
    buffer(sections)
    local original = vim.api.nvim_win_get_cursor(0)
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    local ok, err = tex.jump_section(1)
    eq(false, ok)
    assert(err:find('parser unavailable', 1, true))
    eq(false, tex.jump_item(1))
    eq(original, vim.api.nvim_win_get_cursor(0))
  end)

  test('invalid navigation arguments fail without moving', function()
    buffer(sections)
    local original = vim.api.nvim_win_get_cursor(0)
    for _, fn in ipairs({ tex.jump_section, tex.jump_item }) do
      for _, direction in ipairs({ 0, 2, 'next', false }) do
        eq(false, fn(direction))
      end
      eq(false, fn(nil))
      for _, count in ipairs({ 0, -1, 1.5, math.huge, '2', false, 0 / 0 }) do
        eq(false, fn(1, count))
      end
    end
    eq(original, vim.api.nvim_win_get_cursor(0))
  end)

  test('disabled defaults retain all navigation commands and Plug mappings', function()
    tex.setup({ mappings = false })
    buffer(sections, 'plaintex')
    for _, mapping in ipairs({
      { ']]', 'NextSection' },
      { '[[', 'PreviousSection' },
      { ']i', 'NextItem' },
      { '[i', 'PreviousItem' },
    }) do
      eq('', vim.fn.maparg(mapping[1], 'n'))
      assert(vim.fn.maparg('<Plug>(TexTools' .. mapping[2] .. ')', 'n') ~= '')
      assert(vim.api.nvim_buf_get_commands(0, {})['TexTools' .. mapping[2]])
    end
    vim.keymap.set('n', '<F9>', '<Plug>(TexToolsNextSection)', { buffer = true })
    keys('3<F9>')
    cursor(headings[3])
    tex.setup()
    eq('<Plug>(TexToolsNextSection)', vim.fn.maparg(']]', 'n'))
  end)

  test('navigation preserves existing user mappings through setup', function()
    buffer('intro', 'text')
    vim.keymap.set('n', ']]', 'GLOBAL')
    vim.keymap.set('n', ']i', 'LOCAL', { buffer = true })
    vim.bo.filetype = 'tex'
    eq('GLOBAL', vim.fn.maparg(']]', 'n'))
    eq('LOCAL', vim.fn.maparg(']i', 'n'))
    tex.setup({ mappings = false })
    eq('GLOBAL', vim.fn.maparg(']]', 'n'))
    eq('LOCAL', vim.fn.maparg(']i', 'n'))
    tex.setup()
    eq('GLOBAL', vim.fn.maparg(']]', 'n'))
    eq('LOCAL', vim.fn.maparg(']i', 'n'))
    vim.keymap.del('n', ']]')
    vim.keymap.del('n', ']i', { buffer = true })
    tex.setup()
  end)
end
