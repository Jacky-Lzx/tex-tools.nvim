return function(t)
  local test, eq, buffer, at = t.test, t.eq, t.buffer, t.at
  local tex = require('tex-tools')
  local config = require('tex-tools.config')
  local function await(predicate)
    assert(vim.wait(10000, predicate, 5), 'Formula operation timed out')
  end
  for _, ft in ipairs({ 'tex', 'plaintex', 'latex' }) do
    for _, expression in ipairs({ '$x^2$', '$$x^2$$', '\\(x^2\\)', '\\[x^2\\]' }) do
      test('formula preview detection: ' .. ft .. ' ' .. expression, function()
        tex.setup()
        buffer('前缀 ' .. expression .. ' suffix', ft)
        at('x^2')
        local snapshot = assert(tex.formula_at())
        eq(expression, snapshot.source)
        eq(#'前缀 ', snapshot.range[2])
        at('suffix')
        eq(expression, assert(tex.formula_at()).source)
      end)
    end
  end
  for _, name in ipairs({
    'equation',
    'align*',
    'gather',
    'multline',
    'alignat*',
    'flalign',
    'eqnarray',
    'displaymath',
    'math',
  }) do
    test('formula preview environment: ' .. name, function()
      tex.setup()
      buffer('\\begin{' .. name .. '}\na=b\n\\end{' .. name .. '}\noutside')
      for row = 1, 3 do
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        eq('\\begin{' .. name .. '}\na=b\n\\end{' .. name .. '}', assert(tex.formula_at()).source)
      end
      at('outside')
      eq(nil, tex.formula_at())
    end)
  end
  test('formula preview uses custom math environments', function()
    tex.setup({ math_environments = { 'mymath' } })
    buffer('\\begin{mymath}\na+b\n\\end{mymath}')
    at('a+b')
    assert(tex.formula_at())
    tex.setup()
    eq(nil, tex.formula_at())
  end)
  test('formula preview excludes comments, literal content and incomplete math', function()
    tex.setup()
    for _, fixture in ipairs({
      '% $x$',
      '\\verb|$x$|',
      '\\lstinline|$x$|',
      '\\mintinline{tex}|$x$|',
      '\\newcommand{\\foo}{$x$}',
      '\\begin{minted}{tex}\n$x$\n\\end{minted}',
      '\\begin{verbatim}\n$x$\n\\end{verbatim}',
      '$x',
      '\\[x',
      '\\begin{equation}\nx',
    }) do
      buffer(fixture)
      at('x')
      eq(nil, tex.formula_at())
    end
    buffer('$x$', 'markdown')
    eq(nil, tex.formula_at())
  end)
  test('formula preview selects by cursor and enforces budgets', function()
    tex.setup()
    buffer('$a$ and $b$')
    at('$b$', 1)
    eq('$b$', assert(tex.formula_at()).source)
    at('and')
    eq('$a$', assert(tex.formula_at()).source)
    tex.setup({ formula_preview = { max_lines = 2, max_bytes = 20 } })
    buffer('$$\nx\n$$')
    at('x')
    eq(nil, tex.formula_at())
    buffer('$' .. string.rep('x', 21) .. '$')
    at('x')
    eq(nil, tex.formula_at())
    tex.setup()
  end)
  test('formula preview validates independent configuration', function()
    for _, bad in ipairs({
      { density = 0 },
      { delay = -1 },
      { timeout = math.huge },
      { foreground = 'red' },
      { preamble = false },
      { latex = '' },
      { enabled = 1 },
      { concurrency = 0 },
      { max_cache_entries = 0 },
    }) do
      eq(false, pcall(config.formula_options, bad))
    end
    eq(false, config.formula_options().enabled)
  end)
  test('formula controller retains valid work and rejects stale completion', function()
    local renderer = require('tex-tools.formula.render')
    local original_prepare, original_backend = renderer.prepare, package.loaded.image_tools
    local callbacks, views, cancellations, releases = {}, {}, 0, 0
    local function restore()
      tex.close_formula_preview()
      renderer.prepare, package.loaded.image_tools = original_prepare, original_backend
      tex.setup()
    end
    local ok, err = xpcall(function()
      renderer.prepare = function(source, _, callback)
        callbacks[#callbacks + 1] = { callback = callback, source = source }
        return function()
          cancellations = cancellations + 1
        end
      end
      package.loaded.image_tools = {
        close = function() end,
        float = function(request)
          local view = { request = request }
          function view:close()
            if not self.closed then
              self.closed = true
              request.on_close()
            end
          end
          function view:status()
            return { window = 123, stage = 'ready' }
          end
          views[#views + 1] = view
          return view
        end,
      }
      local function deliver(index)
        callbacks[index].callback(nil, {
          path = '/tmp/generated.png',
          width = 360,
          height = 160,
          display_size = { width = 180, height = 80 },
          release = function()
            releases = releases + 1
          end,
        })
      end
      tex.setup({ formula_preview = { enabled = true, delay = 0 } })
      buffer('$$\nx^2\n$$\noutside')
      at('x^2')
      assert(tex.preview_formula())
      eq(1, #callbacks)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      require('tex-tools.formula').refresh()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      require('tex-tools.formula').refresh()
      eq(1, #callbacks)
      deliver(1)
      eq('ready', tex.formula_info().stage)
      eq({ width = 180, height = 80 }, views[1].request.display_size)
      at('outside')
      require('tex-tools.formula').refresh()
      eq(true, views[1].closed)
      eq(1, releases)
      at('x^2')
      tex.preview_formula()
      at('outside')
      require('tex-tools.formula').refresh()
      deliver(2)
      eq(1, #views)
      eq(2, releases)
      at('x^2')
      tex.preview_formula()
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'x^3' })
      require('tex-tools.formula').refresh()
      eq(4, #callbacks)
      deliver(3)
      eq(1, #views)
      deliver(4)
      eq(2, #views)
      vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'unclosed' })
      require('tex-tools.formula').refresh()
      eq(true, views[2].closed)
      eq(4, releases)
      assert(cancellations >= 3)
      buffer('$a$')
      tex.preview_formula()
      callbacks[5].callback('Invalid formula')
      eq('failed', tex.formula_info().stage)
      eq('Invalid formula', tex.formula_info().error)
      tex.setup({ formula_preview = { enabled = true, delay = 40 } })
      buffer('$a$\noutside')
      at('$a$')
      require('tex-tools.formula').refresh()
      local before = #callbacks
      at('outside')
      require('tex-tools.formula').refresh()
      vim.wait(80, function()
        return false
      end)
      eq(before, #callbacks)
      at('$a$')
      assert(tex.preview_formula())
      eq(before + 1, #callbacks)
      -- Exercise already-queued timer callbacks deterministically: an old
      -- selection must not close its successor, and manual preview expedites
      -- the current selection without starting it twice.
      local defer = vim.defer_fn
      local timers = {}
      vim.defer_fn = function(callback)
        local handle = { callback = callback }
        function handle:is_closing()
          return self.closed == true
        end
        function handle:stop() end
        function handle:close()
          self.closed = true
        end
        timers[#timers + 1] = handle
        return handle
      end
      local timer_ok, timer_err = xpcall(function()
        tex.close_formula_preview()
        buffer('$first$')
        require('tex-tools.formula').refresh()
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { '$second$' })
        require('tex-tools.formula').refresh()
        eq(2, #timers)
        local count = #callbacks
        timers[1].callback()
        eq('$second$', tex.formula_info().source)
        eq('waiting', tex.formula_info().stage)
        tex.preview_formula()
        eq(count + 1, #callbacks)
        timers[2].callback()
        eq(count + 1, #callbacks)
      end, debug.traceback)
      vim.defer_fn = defer
      if not timer_ok then
        error(timer_err)
      end
    end, debug.traceback)
    restore()
    if not ok then
      error(err)
    end
  end)
  test('formula cache keys preserve source and preamble boundaries', function()
    local render = require('tex-tools.formula.render')
    local options = config.formula_options({ foreground = '#ffffff', preamble = 'b\nc' })
    local key = render.key('a', options)
    eq(64, #key)
    assert(key:match('^%x+$'))
    eq(key, render.key('a', vim.deepcopy(options)))
    assert(key ~= render.key('a\nb', vim.tbl_extend('force', options, { preamble = 'c' })))
    options.preamble = 'b\0c'
    assert(render.key('a', options) ~= render.key('a\0b', vim.tbl_extend('force', options, { preamble = 'c' })))
  end)
  test('formula rendering: real PNG, shared workers, leases and stable DPI sizing', function()
    if vim.fn.executable('latex') == 0 or vim.fn.executable('dvipng') == 0 then
      return
    end
    local cache = vim.fn.tempname() .. '-formula-cache'
    local settings = { cache = cache, foreground = '#cad3f5', density = 180 }
    local first, second, failure, shared
    local function callback(which)
      return function(err, image)
        failure = err
        if which == 1 then
          first = image
        else
          second = image
        end
      end
    end
    local command_count, system = 0, vim.system
    vim.system = function(command, options, cb)
      if command[1] == 'latex' or command[1] == 'dvipng' then
        command_count = command_count + 1
      end
      return system(command, options, cb)
    end
    local ok, err = xpcall(function()
      tex.render_formula('$\\frac{a}{b}+\\sqrt{x}$', settings, callback(1))
      tex.render_formula('$\\frac{a}{b}+\\sqrt{x}$', settings, callback(2))
      await(function()
        return failure or first and second
      end)
      assert(not failure, failure)
      eq(2, command_count)
      eq(first.path, second.path)
      eq(0, require('tex-tools.formula.render').clear(cache))
      first.release()
      first.release()
      eq(0, require('tex-tools.formula.render').clear(cache))
      local low = first
      shared = second
      first, second = nil, nil
      tex.render_formula('$\\frac{a}{b}+\\sqrt{x}$', vim.tbl_extend('force', settings, { density = 360 }), callback(1))
      await(function()
        return failure or first
      end)
      assert(not failure, failure)
      assert(first.width > low.width and first.height > low.height)
      assert(math.abs(first.display_size.width - low.display_size.width) <= 2)
      assert(math.abs(first.display_size.height - low.display_size.height) <= 2)
      first.release()
      -- The second subscriber still owns the low-DPI result until released.
      -- Keep its release handle separately from the callback destination.
    end, debug.traceback)
    vim.system = system
    if first then
      first.release()
    end
    if shared then
      shared.release()
    end
    require('tex-tools.formula.render').clear(cache)
    vim.fn.delete(cache, 'rf')
    if not ok then
      error(err)
    end
  end)
  test('formula workers: cancellation, replacement and independent subscribers', function()
    local system = vim.system
    local cache = vim.fn.tempname() .. '-formula-workers'
    local requests, callbacks, kills, delivered = {}, {}, 0, 0
    -- Processes are mocked; use a known executable so TeX need not be installed.
    local options = {
      cache = cache,
      concurrency = 1,
      foreground = '#ffffff',
      latex = vim.v.progpath,
      dvipng = vim.v.progpath,
    }
    local result
    local function await(predicate)
      assert(vim.wait(3000, predicate, 1), 'Worker test timed out')
    end
    vim.system = function(command, opts, callback)
      requests[#requests + 1] = { command = command, options = opts }
      callbacks[#callbacks + 1] = callback
      return {
        kill = function()
          kills = kills + 1
        end,
      }
    end
    local ok, err = xpcall(function()
      local first = tex.render_formula('$x$', options, function()
        delivered = delivered + 1
      end)
      local second = tex.render_formula('$x$', options, function()
        delivered = delivered + 1
      end)
      await(function()
        return #requests == 1
      end)
      first()
      eq(0, kills)
      second()
      eq(1, kills)
      tex.render_formula('$x$', options, function(error_message, image)
        assert(not error_message, error_message)
        result = image
      end)
      callbacks[1]({ code = 143 })
      await(function()
        return #requests == 2
      end)
      callbacks[2]({ code = 0 })
      await(function()
        return #requests == 3
      end)
      local png = vim.base64.decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='
      )
      local output = requests[3].command
      local path
      for i, value in ipairs(output) do
        if value == '-o' then
          path = output[i + 1]
        end
      end
      local fd = assert(vim.uv.fs_open(path, 'w', 384))
      assert(vim.uv.fs_write(fd, png, 0))
      vim.uv.fs_close(fd)
      callbacks[3]({ code = 0 })
      await(function()
        return result
      end)
      eq(0, delivered)
      eq(1, result.width)
      eq(0, require('tex-tools.formula.render').clear(cache))
      result.release()
      eq(1, require('tex-tools.formula.render').clear(cache))
      local failure
      tex.render_formula('$bad$', options, function(message)
        failure = message
      end)
      await(function()
        return #requests == 4
      end)
      callbacks[4]({ code = 1, stderr = 'TeX failed' })
      await(function()
        return failure
      end)
      assert(failure:find('TeX failed', 1, true))
    end, debug.traceback)
    vim.system = system
    if result then
      result.release()
    end
    vim.fn.delete(cache, 'rf')
    if not ok then
      error(err)
    end
  end)
end
