return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local function prompt(value)
    vim.ui.input = function(_, callback)
      callback(value)
    end
  end

  local function selected_range(needle)
    at(needle)
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    return { row - 1, col, row - 1, col + #needle }
  end

  test('rename the innermost command while preserving UTF-8 and other arguments', function()
    buffer('before \\textbf{bold \\emph{中文}} after')
    at('中文')
    eq(true, tex.rename_command('textit'))
    eq('before \\textbf{bold \\textit{中文}} after', content())
  end)

  test('rename preserves stars, whitespace, comments, options, and multiple arguments', function()
    buffer('\\section*[Short]{Title}\nbody\n\\mycmd* {one}% keep\n{two}')
    at('Title')
    eq(true, tex.rename_command('chapter'))
    at('two')
    eq(true, tex.rename_command('other@command*'))
    eq('\\chapter[Short]{Title}\nbody\n\\other@command* {one}% keep\n{two}', content())
  end)

  test('rename works for a command without arguments', function()
    buffer('中文 \\LaTeX after')
    at('LaTeX')
    eq(true, tex.rename_command('TeX'))
    eq('中文 \\TeX after', content())
  end)

  test('command rename prompts with the existing name', function()
    buffer('\\textbf{body}')
    at('body')
    vim.ui.input = function(opts, callback)
      eq({ prompt = 'Command: ', default = 'textbf' }, opts)
      callback('emph')
    end
    eq(true, tex.rename_command())
    eq('\\emph{body}', content())
  end)

  test('renaming a starred bare command refuses token merging', function()
    buffer('\\foo*tail')
    at('foo')
    eq(false, tex.rename_command('bar'))
    eq('\\foo*tail', content())
    eq(true, tex.rename_command('bar*'))
    eq('\\bar*tail', content())
  end)

  test('rename touches only a heading header and leaves its body errors alone', function()
    buffer('\\section{Title}\nbody \\textbf{unfinished')
    at('Title')
    eq(true, tex.rename_command('subsection*'))
    eq('\\subsection*{Title}\nbody \\textbf{unfinished', content())
    at('body')
    eq(false, tex.rename_command('chapter'))
  end)

  local invalid_names = {
    '',
    '\\emph',
    'two words',
    'foo1',
    'foo_bar',
    'foo-bar',
    'foo**',
    '*foo',
    'foo{bar}',
    'foo\nbar',
    '中文',
    false,
    42,
  }
  for i, name in ipairs(invalid_names) do
    test('command edits reject invalid names ' .. i, function()
      buffer('\\textbf{body}')
      at('body')
      local original, cursor = content(), vim.api.nvim_win_get_cursor(0)
      eq(false, tex.rename_command(name))
      eq(false, tex.surround_command(name))
      eq(original, content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  local unwraps = {
    { 'prefix \\textbf{中文} suffix', '中文', 'prefix 中文 suffix' },
    { '\\textbf{first\n中文 \\{literal\\}}', 'first', 'first\n中文 \\{literal\\}' },
    { '\\outer{before \\inner{body} after}', 'body', '\\outer{before body after}' },
    { '\\textbf{}', 'textbf', '' },
    { '\\custom* \n  {body}', 'body', 'body' },
    { '\\section{Title}\nBody text\n{standalone}', 'Title', 'Title\nBody text\n{standalone}' },
    { '\\[x + \\text{words}\\]', 'words', '\\[x + words\\]' },
    { '\\textbf{first % keep\nsecond}', 'first', 'first % keep\nsecond' },
    { '\\textbf{\\alpha} tail', 'textbf', '\\alpha tail' },
    { '\\textbf{\\%}tail', 'textbf', '\\%tail' },
  }
  for i, fixture in ipairs(unwraps) do
    test('unwrap preserves the single argument body ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(true, tex.unwrap_command())
      eq(fixture[3], content())
    end)
  end

  local refused_unwraps = {
    { '\\frac{one}{two}', 'two' },
    { '\\section[Short]{Title}', 'Title' },
    { '\\item[Label] body', 'Label' },
    { '\\LaTeX', 'LaTeX' },
    { '\\newcommand\\foo{body}', 'body' },
    { '\\textbf % keep\n{body}', 'body' },
    { '\\textbf{unfinished', 'unfinished' },
    { '\\foo[unknown]{body}', 'foo' },
    { '\\alpha\\textbf{body}', 'textbf' },
    { '\\textbf{\\alpha}tail', 'textbf' },
    { '\\alpha\\textbf{}tail', 'textbf' },
  }
  for i, fixture in ipairs(refused_unwraps) do
    test('unwrap refuses ambiguous, incomplete, or merging calls ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      local cursor = vim.api.nvim_win_get_cursor(0)
      local ok, err = tex.unwrap_command()
      eq(false, ok)
      assert(type(err) == 'string')
      eq(fixture[1], content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  for _, fixture in ipairs({
    { '% \\textbf{ignored}', 'ignored' },
    { '\\iffalse\n\\textbf{ignored}\n\\fi', 'ignored' },
    { '\\begin{comment}\n\\textbf{ignored}\n\\end{comment}', 'ignored' },
    { '\\begin{verbatim}\n\\textbf{ignored}\n\\end{verbatim}', 'ignored' },
    { '\\begin{minted}{latex}\n\\textbf{ignored}\n\\end{minted}', 'ignored' },
    { '\\begin{quote}\nbody\n\\end{quote}', 'begin' },
    { 'price \\% more', '\\%' },
  }) do
    test('rename and unwrap refuse noneditable command contexts: ' .. fixture[1], function()
      buffer(fixture[1])
      at(fixture[2])
      eq(false, tex.rename_command('emph'))
      eq(false, tex.unwrap_command())
      eq(fixture[1], content())
    end)
  end

  test('surround the current line or an Ex line range without reindenting', function()
    buffer('before\n  first\n中文\nafter')
    at('first')
    eq(true, tex.surround_command('textbf'))
    eq('before\n\\textbf{  first}\n中文\nafter', content())
    buffer('before\n  first\n中文\nafter')
    vim.cmd('2,3TexToolsSurroundCommand emph')
    eq('before\n\\emph{  first\n中文}\nafter', content())
  end)

  local surrounds = {
    { 'before 中文 after', '中文', 'before \\emph{中文} after' },
    { '\\textbf{first second}', 'second', '\\textbf{first \\emph{second}}' },
    { 'before \\textbf{body} after', '\\textbf{body}', 'before \\emph{\\textbf{body}} after' },
    { 'before $x+y$ after', '$x+y$', 'before \\emph{$x+y$} after' },
    { '$x+y$', 'x+y', '$\\emph{x+y}$' },
    { '$\\left(x+y\\right)$', 'x+y', '$\\left(\\emph{x+y}\\right)$' },
    { '\\section{Title}\nbody', 'Title', '\\section{\\emph{Title}}\nbody' },
    { '\\begin{quote}body\\end{quote}', 'body', '\\begin{quote}\\emph{body}\\end{quote}' },
    { '\\begin{quote}body\\end{quote}', '\\begin{quote}body\\end{quote}', '\\emph{\\begin{quote}body\\end{quote}}' },
    { 'price \\% literal', 'price \\% literal', '\\emph{price \\% literal}' },
  }
  for i, fixture in ipairs(surrounds) do
    test('surround a precise byte range with complete syntax ' .. i, function()
      buffer(fixture[1])
      eq(true, tex.surround_command('emph', { range = selected_range(fixture[2]) }))
      eq(fixture[3], content())
    end)
  end

  local unsafe = {
    { '\\textbf{body} after', 'textbf' },
    { '\\textbf{body} after', '{body' },
    { '\\textbf{body} after', 'body} after' },
    { '\\textbf{body} after', '\\textbf' },
    { 'before $x+y$ after', '$x+y' },
    { '$\\left(x+y\\right)$', '\\left(x' },
    { '\\begin{quote}body\\end{quote}', '\\begin{quote}' },
    { 'before % comment', 'before % comment' },
    { '\\textbf{body % comment\nend}', 'comment' },
    { '\\begin{verbatim}\ncode\n\\end{verbatim}', 'code' },
    { '\\begin{minted}{lua}\ncode\n\\end{minted}', 'code' },
    { '\\textbf{unfinished', 'unfinished' },
  }
  for i, fixture in ipairs(unsafe) do
    test('surround refuses partial syntax, comments, and literal selections ' .. i, function()
      buffer(fixture[1])
      local range = selected_range(fixture[2])
      local cursor = vim.api.nvim_win_get_cursor(0)
      eq(false, tex.surround_command('emph', { range = range }))
      eq(fixture[1], content())
      eq(cursor, vim.api.nvim_win_get_cursor(0))
    end)
  end

  test('surround refuses a comment or literal region inside a larger selection', function()
    for _, fixture in ipairs({ 'first\n% comment\nlast', 'first\n\\begin{verbatim}\ncode\n\\end{verbatim}\nlast' }) do
      buffer(fixture)
      eq(false, tex.surround_command('emph', { line1 = 1, line2 = vim.api.nvim_buf_line_count(0) }))
      eq(fixture, content())
    end
  end)

  test('surround refuses to place an opening marker after a line comment', function()
    buffer('text % comment\nbody')
    eq(false, tex.surround_command('emph', { range = { 0, #'text % comment', 1, 4 } }))
    eq('text % comment\nbody', content())
  end)

  test('Visual surround retains composing marks as part of the selected character', function()
    buffer('before á after')
    at('á')
    prompt('emph')
    keys('v,lc')
    eq('before \\emph{á} after', content())
  end)

  test('Visual surround preserves full selected tabs', function()
    buffer('before\tword after')
    at('\tword')
    prompt('emph')
    keys('v4l,lc')
    eq('before\\emph{\tword} after', content())
  end)

  test('Visual surround refuses selected virtual cells beyond the line', function()
    buffer('word')
    local virtualedit = vim.o.virtualedit
    vim.o.virtualedit = 'all'
    prompt('emph')
    keys('$llvll,lc<Esc>')
    vim.o.virtualedit = virtualedit
    eq('word', content())
  end)

  for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
    for _, reverse in ipairs({ false, true }) do
      test('Visual command surround honors UTF-8 and ' .. selection .. ', reverse=' .. tostring(reverse), function()
        buffer('before 中文 after')
        vim.o.selection = selection
        at('中文', reverse and #'中' or 0)
        prompt('textbf')
        if reverse then
          keys('vh,lc')
        elseif selection == 'exclusive' then
          keys('vll,lc')
        else
          keys('vl,lc')
        end
        -- Native exclusive selection omits the higher endpoint in either direction.
        local expected = reverse and selection == 'exclusive' and 'before \\textbf{中}文 after'
          or 'before \\textbf{中文} after'
        eq(expected, content())
      end)
    end
  end

  test('linewise Visual command surround supports a reverse multiline selection', function()
    buffer('before\nfirst\n中文\nafter')
    at('中文')
    prompt('emph')
    keys('Vk,lc')
    eq('before\n\\emph{first\n中文}\nafter', content())
  end)

  test('characterwise multiline surround preserves text outside both boundaries', function()
    buffer('before first\nsecond after')
    at('first')
    prompt('emph')
    keys('vj^5l,lc')
    eq('before \\emph{first\nsecond} after', content())
  end)

  test('blockwise Visual command surround is refused', function()
    buffer('first\nsecond')
    local original = content()
    prompt('emph')
    keys('<C-v>j,lc<Esc>')
    eq(original, content())
  end)

  test('Visual surround API is available for custom mappings', function()
    buffer('before word after')
    at('word')
    vim.keymap.set('x', '<F10>', function()
      eq(true, tex.surround_command_visual('emph'))
    end, { buffer = true })
    keys('viw<F10>')
    eq('before \\emph{word} after', content())
    eq(false, tex.surround_command_visual('emph'))
  end)

  local invalid_ranges = {
    { range = {} },
    { range = { 0, 0, 0 } },
    { range = { 0, 0, 0, 0 } },
    { range = { 0, 2, 0, 1 } },
    { range = { -1, 0, 0, 1 } },
    { range = { 0, 1, 0, 3 } }, -- middle of the first UTF-8 character
    { range = { 0, 0, 0, 1 } }, -- middle of the final UTF-8 character
    { range = { 0, 0, 1, 0 } },
    { range = { 0, 0, 0, 100 } },
    { range = { 0, 0, 0, 1.5 } },
    { range = { 0, 0, 0, math.huge } },
    { range = { 0, 0, 0, 3 }, line1 = 1 },
    { line1 = 0 },
    { line1 = 2 },
    { line2 = '1' },
    { line1 = 1.5 },
    { line1 = false },
    'invalid',
    false,
  }
  for i, opts in ipairs(invalid_ranges) do
    test('surround rejects invalid or empty ranges ' .. i, function()
      buffer('中文')
      eq(false, tex.surround_command('emph', opts))
      eq('中文', content())
    end)
  end

  for _, operation in ipairs({ 'rename', 'surround' }) do
    test(operation .. ' command cancels empty input and refuses stale prompts', function()
      buffer('\\textbf{body}')
      at('body')
      local fn = operation == 'rename' and tex.rename_command or tex.surround_command
      for _, answer in ipairs({ '', false }) do
        prompt(answer or nil)
        eq(true, fn())
        eq('\\textbf{body}', content())
      end
      local callback
      vim.ui.input = function(_, cb)
        callback = cb
      end
      eq(true, fn())
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
      local message
      vim.notify = function(value)
        message = value
      end
      callback('emph')
      assert(message:find('Buffer changed', 1, true))
      eq('changed', content())
    end)
  end

  test('surround copies caller range before opening an asynchronous prompt', function()
    buffer('before body after')
    local range = selected_range('body')
    local callback
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.surround_command(nil, { range = range }))
    range[2], range[4] = 0, 3
    callback('emph')
    eq('before \\emph{body} after', content())
  end)

  test('a delayed command rename edits its original buffer after a buffer switch', function()
    local bufnr = buffer('\\textbf{body}')
    at('body')
    local callback
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.rename_command())
    buffer('other buffer')
    callback('emph')
    eq('other buffer', content())
    eq({ '\\emph{body}' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  test('command operations refuse an unmodifiable buffer before prompting', function()
    buffer('\\textbf{body}')
    at('body')
    vim.ui.input = function()
      error('unexpected prompt')
    end
    vim.bo.modifiable = false
    local renamed, unwrapped, surrounded = tex.rename_command(), tex.unwrap_command(), tex.surround_command()
    vim.bo.modifiable = true
    eq(false, renamed)
    eq(false, unwrapped)
    eq(false, surrounded)
    eq('\\textbf{body}', content())
  end)

  test('command APIs report missing parser without editing', function()
    buffer('\\textbf{body}')
    at('body')
    vim.treesitter.get_parser = function()
      error('not installed')
    end
    eq(false, tex.rename_command('emph'))
    eq(false, tex.unwrap_command())
    local ok, err = tex.surround_command('emph')
    eq(false, ok)
    assert(err:find('parser unavailable', 1, true))
    eq('\\textbf{body}', content())
  end)

  for _, operation in ipairs({ 'rename', 'unwrap', 'surround' }) do
    test(operation .. ' command is one undo operation', function()
      buffer('before \\textbf{中文} after')
      at('中文')
      local original = content()
      vim.cmd('let &undolevels = &undolevels')
      if operation == 'rename' then
        eq(true, tex.rename_command('emph'))
      elseif operation == 'unwrap' then
        eq(true, tex.unwrap_command())
      else
        eq(true, tex.surround_command('emph', { range = selected_range('中文') }))
      end
      vim.cmd.undo()
      eq(original, content())
    end)
  end

  test('Normal command-editing mappings and user commands operate on actual syntax', function()
    buffer('\\textbf{body}')
    at('body')
    prompt('emph')
    keys('csc')
    eq('\\emph{body}', content())
    at('body')
    keys('dsc')
    eq('body', content())
    keys(',lc')
    eq('\\emph{body}', content())
    at('body')
    vim.cmd('TexToolsRenameCommand textit')
    eq('\\textit{body}', content())
    at('body')
    vim.cmd.TexToolsUnwrapCommand()
    eq('body', content())
  end)

  test('disabled defaults retain command-editing commands and Plug mappings', function()
    tex.setup({ mappings = false })
    buffer('word', 'plaintex')
    for _, entry in ipairs({
      { 'n', 'csc', 'RenameCommand' },
      { 'n', 'dsc', 'UnwrapCommand' },
      { 'n', ',lc', 'SurroundCommand' },
      { 'x', ',lc', 'SurroundCommand' },
    }) do
      eq('', vim.fn.maparg(entry[2], entry[1]))
      assert(vim.fn.maparg('<Plug>(TexTools' .. entry[3] .. ')', entry[1]) ~= '')
      assert(vim.api.nvim_buf_get_commands(0, {})['TexTools' .. entry[3]])
    end
    tex.setup()
  end)

  test('command editing preserves existing global and Visual user mappings', function()
    buffer('word', 'text')
    vim.keymap.set('n', 'csc', 'GLOBAL')
    vim.keymap.set('x', ',lc', 'LOCAL', { buffer = true })
    vim.bo.filetype = 'tex'
    tex.setup()
    eq('GLOBAL', vim.fn.maparg('csc', 'n'))
    eq('LOCAL', vim.fn.maparg(',lc', 'x'))
    tex.setup({ mappings = false })
    eq('GLOBAL', vim.fn.maparg('csc', 'n'))
    eq('LOCAL', vim.fn.maparg(',lc', 'x'))
    vim.keymap.del('n', 'csc')
    vim.keymap.del('x', ',lc', { buffer = true })
    tex.setup()
  end)
end
