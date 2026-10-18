return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')

  local named = {
    {
      name = 'command rename',
      key = ',lcr',
      value = 'emph',
      source = '\\textbf{first}\n\\textit{second}\n\\textsc{third}',
      expected = '\\emph{first}\n\\emph{second}\n\\emph{third}',
    },
    {
      name = 'environment rename',
      key = ',ler',
      value = 'theorem',
      source = '\\begin{quote}first\\end{quote}\n\\begin{center}second\\end{center}\n\\begin{flushleft}third\\end{flushleft}',
      expected = '\\begin{theorem}first\\end{theorem}\n\\begin{theorem}second\\end{theorem}\n\\begin{theorem}third\\end{theorem}',
    },
    {
      name = 'math bracket change',
      key = ',ldc',
      value = 'brace',
      source = '$(first)$\n$\\left[second\\right]$\n$\\langle third\\rangle$',
      expected = '$\\{first\\}$\n$\\left\\{second\\right\\}$\n$\\{ third\\}$',
    },
  }
  for _, case in ipairs(named) do
    test('native dot repeats ' .. case.name .. ' with the resolved input', function()
      buffer(case.source)
      at('first')
      local prompts = 0
      vim.ui.input = function(_, callback)
        prompts = prompts + 1
        callback(case.value)
      end
      keys(case.key)
      vim.ui.input = function()
        error('repeat must not prompt')
      end
      at('second')
      keys('.')
      at('third')
      keys('.')
      eq(case.expected, content())
      eq(1, prompts)
    end)
  end

  local unwrapping = {
    { 'command', ',lcd', '\\textbf{first}\n\\emph{second}', 'first\nsecond' },
    {
      'inline environment',
      ',led',
      '\\begin{quote}first\\end{quote}\n\\begin{center}second\\end{center}',
      'first\nsecond',
    },
    {
      'standalone environment',
      ',led',
      '\\begin{quote}\nfirst\n\\end{quote}\n\\begin{center}\nsecond\n\\end{center}',
      'first\nsecond',
    },
    { 'math bracket', ',ldd', '$(first)$\n$\\left[second\\right]$', '$first$\n$second$' },
  }
  for _, case in ipairs(unwrapping) do
    test('native dot unwraps the new ' .. case[1], function()
      buffer(case[3])
      at('first')
      keys(case[2])
      at('second')
      keys('.')
      eq(case[4], content())
    end)
  end

  local toggles = {
    {
      'environment star',
      ',let',
      '\\begin{quote}first\\end{quote}\n\\begin{center*}second\\end{center*}',
      '\\begin{quote*}first\\end{quote*}\n\\begin{center}second\\end{center}',
    },
    { 'bracket size', ',ldt', '$(first)$\n$\\left[second\\right]$', '$\\left(first\\right)$\n$[second]$' },
    { 'formula spelling', ',lf', '$first$\n\\[second\\]', '\\(first\\)\n$$second$$' },
  }
  for _, case in ipairs(toggles) do
    test('native dot toggles the target state for ' .. case[1], function()
      buffer(case[3])
      at('first')
      keys(case[2])
      at('second')
      keys('.')
      eq(case[4], content())
    end)
  end

  test('counted dot unwraps nested commands in one undo step', function()
    buffer('\\textbf{first}\n\\outer{\\middle{\\inner{中文}}}')
    at('first')
    keys(',lcd')
    local before = content()
    at('中文')
    keys('3.')
    eq('first\n中文', content())
    keys('u')
    eq(before, content())
    keys('<C-r>')
    eq('first\n中文', content())
  end)

  test('counted dot toggles repeatedly at the current cursor', function()
    buffer('$(first)$\n$[second]$')
    at('first')
    keys(',ldt')
    at('second')
    keys('2.')
    eq('$\\left(first\\right)$\n$[second]$', content())
    keys('3.')
    eq('$\\left(first\\right)$\n$\\left[second\\right]$', content())
  end)

  test('counted dot stops when a surrounding structure is exhausted', function()
    buffer('\\textbf{first}\n\\outer{\\inner{second}}')
    at('first')
    keys(',lcd')
    local before, messages = content(), {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    at('second')
    keys('3.')
    eq('first\nsecond', content())
    eq(1, #messages)
    keys('u')
    eq(before, content())
  end)

  test('each dot is a separate undo step and redo restores paired edits', function()
    local original = '\\textbf{first}\n\\textit{second}'
    buffer(original)
    vim.cmd('let &undolevels = &undolevels')
    at('first')
    eq(true, tex.rename_command('emph'))
    local first = content()
    at('second')
    keys('.')
    eq('\\emph{first}\n\\emph{second}', content())
    keys('u')
    eq(first, content())
    keys('u')
    eq(original, content())
    keys('<C-r>')
    eq(first, content())
    keys('<C-r>')
    eq('\\emph{first}\n\\emph{second}', content())
  end)

  test('dot re-queries the structure after unrelated changes and UTF-8 offsets', function()
    buffer('中文 \\textbf{first}\n\\textit{second}')
    at('first')
    eq(true, tex.rename_command('emph'))
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'extra line' })
    at('second')
    keys('.')
    eq('extra line\n中文 \\emph{first}\n\\emph{second}', content())
  end)

  test('invalid repeat leaves text/cursor untouched and can be retried at a valid target', function()
    buffer('\\textbf{first}\nplain\n\\textit{second}')
    at('first')
    eq(true, tex.rename_command('emph'))
    local original, messages = content(), {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    at('plain', 2)
    local cursor = vim.api.nvim_win_get_cursor(0)
    keys('.')
    eq(original, content())
    eq(cursor, vim.api.nvim_win_get_cursor(0))
    eq(1, #messages)
    at('second')
    keys('.')
    eq('\\emph{first}\nplain\n\\emph{second}', content())
  end)

  for _, fixture in ipairs({
    '% \\textit{ignored}',
    '\\iffalse\n\\textit{ignored}\n\\fi',
    '\\begin{verbatim}\n\\textit{ignored}\n\\end{verbatim}',
  }) do
    test('dot refuses comments and literal content: ' .. fixture, function()
      buffer('\\textbf{first}\n' .. fixture)
      at('first')
      eq(true, tex.rename_command('emph'))
      local original = content()
      at('ignored')
      vim.notify = function() end
      keys('.')
      eq(original, content())
    end)
  end

  test('environment repeat does not target an enclosing environment from a comment', function()
    buffer('\\begin{quote}first\\end{quote}\n\\begin{center}\n% ignored\nsecond\n\\end{center}')
    at('first')
    eq(true, tex.rename_environment('theorem'))
    local original = content()
    at('ignored')
    vim.notify = function() end
    keys('.')
    eq(original, content())
    at('second')
    keys('.')
    eq('theorem', tex.environment().name)
  end)

  test('dot refuses unmodifiable buffers without forgetting the action', function()
    buffer('\\textbf{first}\n\\textit{second}')
    at('first')
    eq(true, tex.rename_command('emph'))
    at('second')
    local original = content()
    vim.bo.modifiable = false
    vim.notify = function() end
    keys('.')
    eq(original, content())
    vim.bo.modifiable = true
    keys('.')
    eq('\\emph{first}\n\\emph{second}', content())
  end)

  test('dot reports a missing parser and can recover', function()
    buffer('\\textbf{first}\n\\textit{second}')
    at('first')
    eq(true, tex.rename_command('emph'))
    at('second')
    local get_parser, original, message = vim.treesitter.get_parser, content()
    vim.treesitter.get_parser = function()
      error('missing parser')
    end
    vim.notify = function(value)
      message = value
    end
    keys('.')
    eq(original, content())
    assert(message:find('parser unavailable', 1, true))
    vim.treesitter.get_parser = get_parser
    keys('.')
    eq('\\emph{first}\n\\emph{second}', content())
  end)

  for _, outcome in ipairs({ 'cancel', 'empty', 'invalid', 'stale', 'failed', 'no-op' }) do
    test(outcome .. ' initial edits preserve native dot and operatorfunc', function()
      buffer('\\textbf{first}\n\\textit{second}')
      at('first')
      keys('A!<Esc>')
      at('first')
      local previous = vim.go.operatorfunc
      if outcome == 'failed' then
        eq(false, tex.unwrap_math_delimiters())
      elseif outcome == 'no-op' then
        eq(true, tex.rename_command('textbf'))
      else
        local callback
        vim.ui.input = function(_, cb)
          callback = cb
        end
        eq(true, tex.rename_command())
        vim.notify = function() end
        if outcome == 'stale' then
          vim.api.nvim_buf_set_text(0, 0, 0, 0, 0, { 'prefix ' })
          callback('emph')
        elseif outcome == 'invalid' then
          callback('bad name')
        elseif outcome == 'empty' then
          callback('')
        else
          callback(nil)
        end
      end
      eq(previous, vim.go.operatorfunc)
      at('second')
      keys('.')
      local prefix = outcome == 'stale' and 'prefix ' or ''
      eq(prefix .. '\\textbf{first}!\n\\textit{second}!', content())
    end)
  end

  test('native insertion replaces structural dot', function()
    buffer('\\textbf{first}\nplain')
    at('first')
    eq(true, tex.rename_command('emph'))
    at('plain')
    keys('A!<Esc>')
    keys('.')
    eq('\\emph{first}\nplain!!', content())
  end)

  test('native operator edits replace structural dot', function()
    buffer('\\textbf{first}\nalpha beta gamma')
    at('first')
    eq(true, tex.rename_command('emph'))
    at('alpha')
    keys('diw')
    at('beta')
    keys('.')
    eq('\\emph{first}\n  gamma', content())
  end)

  test('another native g@ operator supplies its own dot repeat', function()
    buffer('\\textbf{first}\nplain')
    at('first')
    eq(true, tex.rename_command('emph'))
    local previous = vim.go.operatorfunc
    _G.TexToolsTestOperator = function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { '!' })
    end
    vim.go.operatorfunc = 'v:lua.TexToolsTestOperator'
    at('plain')
    keys('g@l')
    keys('.')
    local result = content()
    vim.go.operatorfunc = previous
    _G.TexToolsTestOperator = nil
    eq('\\emph{first}\n!!plain', result)
  end)

  test('a successful asynchronous prompt records only its resolved value', function()
    buffer('\\textbf{first}\n\\textit{second}')
    at('first')
    local callback
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.rename_command())
    at('second')
    callback('emph')
    vim.ui.input = function()
      error('repeat must not prompt')
    end
    at('second')
    keys('.')
    eq('\\emph{first}\n\\emph{second}', content())
  end)

  test('an asynchronous edit in a hidden buffer preserves the current native repeat', function()
    local original = buffer('\\textbf{first}')
    at('first')
    local callback
    vim.ui.input = function(_, cb)
      callback = cb
    end
    eq(true, tex.rename_command())
    buffer('elsewhere')
    keys('A!<Esc>')
    callback('emph')
    keys('.')
    eq('elsewhere!!', content())
    eq({ '\\emph{first}' }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
  end)

  test('structural dot works across tex buffers and refuses other filetypes', function()
    buffer('\\textbf{first}')
    at('first')
    eq(true, tex.rename_command('emph'))
    buffer('\\textit{second}', 'lua')
    at('second')
    vim.notify = function() end
    keys('.')
    eq('\\textit{second}', content())
    vim.bo.filetype = 'plaintex'
    keys('.')
    eq('\\emph{second}', content())
  end)

  test('Ex commands and Plug mappings record repeat with defaults disabled', function()
    tex.setup({ mappings = false })
    buffer('$(first)$\n$[second]$')
    at('first')
    vim.cmd('TexToolsChangeMathDelimiters brace')
    at('second')
    keys('.')
    eq('$\\{first\\}$\n$\\{second\\}$', content())
    at('first')
    keys('<Plug>(TexToolsUnwrapMathDelimiters)')
    at('second')
    keys('.')
    eq('$first$\n$second$', content())
    tex.setup()
  end)

  test('recording preserves cursor, viewport, registers, and an existing dot mapping', function()
    buffer('中文 \\textbf{first} tail')
    at('first', 2)
    vim.fn.setreg('a', 'keep register')
    vim.fn.setreg('"', 'keep unnamed')
    local hits = 0
    vim.keymap.set('n', '.', function()
      hits = hits + 1
    end, { buffer = true })
    local before = vim.fn.winsaveview()
    eq(true, tex.rename_command('textit'))
    eq(before, vim.fn.winsaveview())
    eq('keep register', vim.fn.getreg('a'))
    eq('keep unnamed', vim.fn.getreg('"'))
    keys('.')
    eq(1, hits)
    eq('中文 \\textit{first} tail', content())
    vim.keymap.del('n', '.', { buffer = true })
  end)

  test('recording ignores a user g@ mapping', function()
    buffer('\\textbf{first}\n\\textit{second}')
    vim.keymap.set('n', 'g@', function()
      error('user g@ mapping was invoked')
    end, { buffer = true })
    at('first')
    eq(true, tex.rename_command('emph'))
    at('second')
    keys('.')
    eq('\\emph{first}\n\\emph{second}', content())
    vim.keymap.del('n', 'g@', { buffer = true })
  end)

  test('empty-buffer edits can still record a later repeat', function()
    buffer('\\textbf{}')
    eq(true, tex.unwrap_command())
    eq('', content())
    buffer('\\textit{body}')
    at('body')
    keys('.')
    eq('body', content())
  end)

  test('API edits inside Insert mode do not interrupt typing', function()
    buffer('\\textbf{body}')
    at('body')
    vim.keymap.set('i', '<F6>', function()
      eq('i', vim.fn.mode())
      eq(true, tex.rename_command('emph'))
      eq('i', vim.fn.mode())
    end, { buffer = true })
    keys('i<F6>X<Esc>')
    eq('\\emph{Xbody}', content())
  end)
end
