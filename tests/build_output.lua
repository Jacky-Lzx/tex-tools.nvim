return function(h)
  local tex, manager = require('tex-tools'), require('tex-tools.build')
  local eq = h.eq
  local function check(name, fn)
    h.test('build output: ' .. name, function()
      local get_clients, notify = vim.lsp.get_clients, vim.notify
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.notify = get_clients, notify
      vim.cmd('silent! only!')
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function fixture()
    local bufnr = h.buffer('\\documentclass{article}')
    vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. '.tex')
    local client = { id = bufnr + 20000, name = 'texlab', settings = { texlab = { build = {} } }, handlers = {} }
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    return client, bufnr
  end

  check('stream capture preserves custom handlers and attachment is idempotent', function()
    local client = fixture()
    local received = 0
    client.handlers['window/logMessage'] = function()
      received = received + 1
    end
    manager.attach(client)
    local handler = client.handlers['window/logMessage']
    manager.attach(client)
    eq(handler, client.handlers['window/logMessage'])
    handler(nil, { type = 4, message = 'one\ntwo\n' }, { client_id = client.id })
    handler(nil, { type = 3, message = 'server information' }, { client_id = client.id })
    eq(2, received)
    eq({ 'one', 'two' }, manager.state(client).output_lines)
    eq(nil, manager.state(client).output_buffer)
  end)

  check('output is bounded, strips terminal colors, and is isolated per client', function()
    local first = fixture()
    local second = fixture()
    tex.setup({ build = { output_lines = 2 } })
    manager.attach(first)
    manager.attach(second)
    first.handlers['window/logMessage'](
      nil,
      { type = 4, message = 'old\n\27[31mred\27[0m\nlast' },
      { client_id = first.id }
    )
    second.handlers['window/logMessage'](nil, { type = 4, message = 'other' }, { client_id = second.id })
    eq({ 'red', 'last' }, manager.state(first).output_lines)
    eq({ 'other' }, manager.state(second).output_lines)
    manager.begin(first, 'file:///tmp/main.tex')
    eq({}, manager.state(first).output_lines)
    eq({ 'other' }, manager.state(second).output_lines)
  end)

  check('live output window is read-only, reusable, and follows updates', function()
    local client = fixture()
    manager.attach(client)
    client.handlers['window/logMessage'](nil, { type = 4, message = 'before opening' }, { client_id = client.id })
    local ok, bufnr = tex.build_output()
    eq(true, ok)
    eq(
      true,
      vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == 'before opening'
      end)
    )
    eq(false, vim.bo[bufnr].modifiable)
    eq('nofile', vim.bo[bufnr].buftype)
    local windows = #vim.api.nvim_list_wins()
    eq(true, tex.build_output())
    eq(windows, #vim.api.nvim_list_wins())
    client.handlers['window/logMessage'](nil, { type = 4, message = 'after opening' }, { client_id = client.id })
    eq(
      true,
      vim.wait(1000, function()
        return vim.api.nvim_buf_line_count(bufnr) == 2
      end)
    )
    eq({ 'before opening', 'after opening' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    manager.begin(client, 'file:///tmp/new.tex')
    eq(
      true,
      vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ''
      end)
    )
  end)

  check('errors list includes only the selected texlab client and respects severity', function()
    local client, bufnr = fixture()
    local namespace = vim.lsp.diagnostic.get_namespace(client.id, false)
    local other = vim.api.nvim_create_namespace('tex-tools.test.other')
    vim.diagnostic.set(namespace, bufnr, {
      { lnum = 0, col = 0, message = 'compiler error', severity = vim.diagnostic.severity.ERROR },
      { lnum = 0, col = 1, message = 'compiler warning', severity = vim.diagnostic.severity.WARN },
      { lnum = 0, col = 2, message = 'information', severity = vim.diagnostic.severity.INFO },
    })
    vim.diagnostic.set(other, bufnr, { { lnum = 0, col = 0, message = 'other server', severity = 1 } })
    eq({ true, 2 }, { tex.build_errors({ open = false }) })
    eq(2, #vim.fn.getqflist())
    eq({ true, 1 }, { tex.build_errors({ errors_only = true, open = false }) })
    eq('compiler error', vim.fn.getqflist()[1].text)
    vim.diagnostic.reset(namespace)
    eq({ true, 0 }, { tex.build_errors({ open = false }) })
    eq({}, vim.fn.getqflist())
    vim.diagnostic.reset(other)
  end)

  check('main-file directives, spaces and configured log directories resolve safely', function()
    local client, bufnr = fixture()
    local directory = vim.fn.tempname() .. ' project'
    vim.fn.mkdir(directory .. '/chapters', 'p')
    vim.fn.mkdir(directory .. '/logs', 'p')
    vim.fn.writefile({ '\\documentclass{article}' }, directory .. '/main.tex')
    vim.fn.writefile({ 'full log' }, directory .. '/logs/main.log')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/chapters/child.tex')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '% !TeX root = ../main.tex', 'child' })
    client.settings.texlab.build.logDirectory = 'logs'
    local ok, path = tex.build_log()
    eq(true, ok)
    eq(directory .. '/logs/main.log', path)
    eq(path, vim.api.nvim_buf_get_name(0))
    eq(true, vim.bo.readonly)
    eq({ 'full log' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.fn.delete(directory, 'rf')
  end)

  check('explicit logs require no server and filenames are not Ex commands', function()
    fixture()
    vim.lsp.get_clients = function()
      return {}
    end
    local path = vim.fn.tempname() .. ' | let g:tex_tools_injected=1 |.log'
    vim.fn.writefile({ 'safe log' }, path)
    eq(true, tex.build_log(path))
    eq(nil, vim.g.tex_tools_injected)
    eq(path, vim.api.nvim_buf_get_name(0))
    vim.fn.delete(path)
  end)

  check('ambiguous roots, cycles and missing logs return useful errors', function()
    local _, bufnr = fixture()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'child without a root' })
    local ok, err = tex.build_log()
    eq(false, ok)
    eq(true, err:find('ambiguous', 1, true) ~= nil)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '% !TeX root = ' .. vim.api.nvim_buf_get_name(bufnr) })
    ok, err = tex.build_log()
    eq(false, ok)
    eq(true, err:find('Cyclic', 1, true) ~= nil)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '\\documentclass{article}' })
    eq(false, tex.build_log())
  end)

  check('real LSP transport supplies output, progress, response status and diagnostics', function()
    local bufnr = h.buffer('\\documentclass{article}')
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, 'p')
    local path = directory .. '/main.tex'
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.fn.writefile({ '\\documentclass{article}' }, path)
    vim.bo.modified = false
    tex.setup()
    local messages = 0
    local id = vim.lsp.start({
      name = 'texlab',
      root_dir = directory,
      cmd = {
        vim.fn.exepath('nvim'),
        '--clean',
        '--headless',
        '-i',
        'NONE',
        '-l',
        vim.fn.getcwd() .. '/tests/fixtures/texlab.lua',
      },
      handlers = {
        ['window/logMessage'] = function()
          messages = messages + 1
        end,
      },
    })
    local client = assert(vim.lsp.get_client_by_id(id))
    local ok, err = xpcall(function()
      eq(
        true,
        vim.wait(3000, function()
          return client.initialized and vim.lsp.buf_is_attached(bufnr, id)
        end)
      )
      eq(true, tex.build())
      eq(
        true,
        vim.wait(3000, function()
          return manager.snapshot(client).phase == 'failed'
        end)
      )
      eq(2, messages)
      eq({ 'compiler output: line one', 'compiler output: line two' }, manager.state(client).output_lines)
      eq({ true, 1 }, { tex.build_errors({ open = false }) })
      eq('fixture compile error', vim.fn.getqflist()[1].text)
    end, debug.traceback)
    client:stop(true)
    vim.wait(1000, function()
      return vim.lsp.get_client_by_id(id) == nil
    end)
    vim.fn.delete(directory, 'rf')
    if not ok then
      error(err)
    end
  end)
end
