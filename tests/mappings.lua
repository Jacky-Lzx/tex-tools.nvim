return function(h)
  local test, eq, buffer, keys = h.test, h.eq, h.buffer, h.keys
  local tex = require('tex-tools')

  local cases = {
    { 'n', ',lEr', '<Plug>(TexToolsRenameEnvironment)' },
    { 'i', ']]', '<Plug>(TexToolsCloseDelimiter)' },
    { 'x', ',lcs', '<Plug>(TexToolsSurroundCommand)' },
    { 'x', 'ae', '<Plug>(TexToolsAroundEnvironment)' },
    { 'o', 'ae', '<Plug>(TexToolsAroundEnvironment)' },
  }

  for _, case in ipairs(cases) do
    local mode, lhs, plug = unpack(case)
    for _, scope in ipairs({ 'global', 'local' }) do
      test('mapping overwrite and restore: ' .. scope .. ' ' .. mode .. ' ' .. lhs, function()
        tex.setup({ mappings = false })
        buffer('x')
        vim.keymap.set(mode, lhs, 'USER', { buffer = scope == 'local' })
        tex.setup()
        eq('USER', vim.fn.maparg(lhs, mode))
        tex.setup({ overwrite_mappings = true })
        eq(plug, vim.fn.maparg(lhs, mode))
        eq(1, vim.fn.maparg(lhs, mode, false, true).buffer)
        -- Repeated setup must keep the original snapshot, not the Plug mapping.
        tex.setup({ overwrite_mappings = true })
        eq(plug, vim.fn.maparg(lhs, mode))
        tex.setup()
        eq('USER', vim.fn.maparg(lhs, mode))
        eq(scope == 'local' and 1 or 0, vim.fn.maparg(lhs, mode, false, true).buffer)
        vim.keymap.del(mode, lhs, { buffer = scope == 'local' })
        tex.setup()
      end)
    end
  end

  test('overwrite restores Lua callbacks and mapping options when disabled', function()
    tex.setup({ mappings = false })
    buffer('x')
    local calls = 0
    local callback = function()
      calls = calls + 1
      return '<Ignore>'
    end
    vim.keymap.set('n', ',lEr', callback, {
      buffer = true,
      expr = true,
      silent = true,
      nowait = true,
      desc = 'user callback',
    })
    tex.setup({ overwrite_mappings = true })
    tex.setup({ mappings = false, overwrite_mappings = true })
    local restored = vim.fn.maparg(',lEr', 'n', false, true)
    eq(callback, restored.callback)
    eq('user callback', restored.desc)
    eq(1, restored.expr)
    eq(1, restored.silent)
    eq(1, restored.nowait)
    eq(1, restored.noremap)
    keys(',lEr')
    eq(1, calls)
    tex.setup()
  end)

  test('overwrite uses the latest global mapping when disabled', function()
    tex.setup({ mappings = false })
    buffer('x')
    vim.keymap.set('n', ']m', 'OLD')
    tex.setup({ overwrite_mappings = true })
    vim.keymap.set('n', ']m', 'NEW')
    tex.setup({ mappings = false })
    eq('NEW', vim.fn.maparg(']m', 'n'))
    vim.keymap.del('n', ']m')
    tex.setup()
  end)

  test('clearing overwritten mappings preserves later user replacements and deletions', function()
    tex.setup({ mappings = false })
    buffer('x')
    vim.keymap.set('n', ',lEr', 'OLD', { buffer = true })
    vim.keymap.set('n', ']m', 'OLD', { buffer = true })
    tex.setup({ overwrite_mappings = true })
    vim.keymap.set('n', ',lEr', 'NEW', { buffer = true })
    vim.keymap.del('n', ']m', { buffer = true })
    tex.setup({ mappings = false })
    eq('NEW', vim.fn.maparg(',lEr', 'n'))
    eq('', vim.fn.maparg(']m', 'n'))
    tex.setup()
  end)

  test('clearing mappings preserves user changes to options with the same rhs', function()
    tex.setup({ overwrite_mappings = true })
    buffer('x')
    vim.keymap.set('n', ',lEr', '<Plug>(TexToolsRenameEnvironment)', {
      buffer = true,
      desc = 'user replacement',
      nowait = true,
    })
    tex.setup({ mappings = false })
    eq('user replacement', vim.fn.maparg(',lEr', 'n', false, true).desc)
    tex.setup()
  end)

  test('overwrite attaches to future TeX buffers and leaves other filetypes alone', function()
    tex.setup({ overwrite_mappings = true })
    buffer('x', 'lua')
    vim.keymap.set('n', ',lEr', 'USER', { buffer = true })
    eq('USER', vim.fn.maparg(',lEr', 'n'))
    vim.bo.filetype = 'plaintex'
    eq('<Plug>(TexToolsRenameEnvironment)', vim.fn.maparg(',lEr', 'n'))
    tex.setup({ mappings = false })
    eq('USER', vim.fn.maparg(',lEr', 'n'))
    tex.setup()
  end)

  test('overwrite does not enable mappings or smart Enter implicitly', function()
    tex.setup({ mappings = false, overwrite_mappings = true, smart_enter = true })
    buffer('x')
    eq('', vim.fn.maparg(',lEr', 'n'))
    eq('', vim.fn.maparg('<CR>', 'i'))
    assert(vim.fn.maparg('<Plug>(TexToolsRenameEnvironment)', 'n') ~= '')
    tex.setup({ overwrite_mappings = true })
    eq('', vim.fn.maparg('<CR>', 'i'))
    tex.setup()
  end)

  test('overwrite restores Visual mappings without changing Select mode', function()
    tex.setup({ mappings = false })
    buffer('x')
    vim.keymap.set('v', 'ae', 'USER', { buffer = true })
    tex.setup({ overwrite_mappings = true })
    eq('<Plug>(TexToolsAroundEnvironment)', vim.fn.maparg('ae', 'x'))
    eq('USER', vim.fn.maparg('ae', 's'))
    tex.setup({ mappings = false })
    eq('USER', vim.fn.maparg('ae', 'x'))
    eq('USER', vim.fn.maparg('ae', 's'))
    tex.setup()
  end)

  test('overwrite restores mappings in their original buffers after leader changes', function()
    tex.setup({ mappings = false })
    local first = buffer('first')
    vim.keymap.set('n', ',lEr', 'FIRST', { buffer = true })
    local second = buffer('second')
    vim.keymap.set('n', ',lEr', 'SECOND', { buffer = true })
    tex.setup({ overwrite_mappings = true })
    vim.g.maplocalleader = ';'
    local ok, err = pcall(function()
      tex.setup({ mappings = false })
      vim.api.nvim_buf_call(first, function()
        eq('FIRST', vim.fn.maparg(',lEr', 'n'))
      end)
      vim.api.nvim_buf_call(second, function()
        eq('SECOND', vim.fn.maparg(',lEr', 'n'))
      end)
    end)
    vim.g.maplocalleader = ','
    tex.setup()
    assert(ok, err)
  end)

  test('FileType replay does not reapply overwrite after a user replaces a key', function()
    tex.setup({ overwrite_mappings = true })
    local bufnr = buffer('x')
    vim.keymap.set('n', ',lEr', 'LATER', { buffer = true })
    vim.api.nvim_exec_autocmds('FileType', { group = 'TexTools', buffer = bufnr })
    eq('LATER', vim.fn.maparg(',lEr', 'n'))
    tex.setup()
    eq('LATER', vim.fn.maparg(',lEr', 'n'))
  end)

  test('overwrite smart Enter restores an existing expression callback', function()
    tex.setup({ mappings = false })
    buffer('x')
    local callback = function()
      return 'USER'
    end
    vim.keymap.set('i', '<CR>', callback, { buffer = true, expr = true, desc = 'completion' })
    tex.setup({ overwrite_mappings = true, smart_enter = true })
    eq('<Plug>(TexToolsSmartEnter)', vim.fn.maparg('<CR>', 'i'))
    tex.setup({ overwrite_mappings = true })
    eq(callback, vim.fn.maparg('<CR>', 'i', false, true).callback)
    eq('completion', vim.fn.maparg('<CR>', 'i', false, true).desc)
    tex.setup()
  end)

  test('overwrite option rejects invalid values without changing installed mappings', function()
    buffer('x')
    local before = vim.fn.maparg(',lEr', 'n')
    local ok, err = pcall(tex.setup, { overwrite_mappings = 'yes' })
    eq(false, ok)
    assert(err:find('overwrite_mappings', 1, true))
    eq(false, require('tex-tools.config').options.overwrite_mappings)
    eq(before, vim.fn.maparg(',lEr', 'n'))
  end)
end
