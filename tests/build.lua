return function(h)
  local tex, manager = require('tex-tools'), require('tex-tools.build')
  local test, eq = h.test, h.eq
  local next_client = 9000

  local function fixture()
    local bufnr = h.buffer('\\documentclass{article}\n\\begin{document}text\\end{document}')
    local path = vim.fn.tempname() .. '.tex'
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.bo[bufnr].modified = false
    next_client = next_client + 1
    local calls = {}
    local client = {
      id = next_client,
      name = 'texlab',
      settings = { texlab = { build = { onSave = false } } },
      server_capabilities = { executeCommandProvider = { commands = { 'texlab.cancelBuild' } } },
      handlers = {},
    }
    function client:request(method, params, callback, target)
      calls[#calls + 1] = { method = method, params = params, callback = callback, bufnr = target }
      return true, #calls
    end
    function client:notify(method, params)
      self.notification = { method = method, params = params }
      return true
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    return client, calls, bufnr, path
  end

  local function check(name, fn)
    test('build management: ' .. name, function()
      local get_clients, get_client, notify = vim.lsp.get_clients, vim.lsp.get_client_by_id, vim.notify
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.lsp.get_client_by_id, vim.notify = get_clients, get_client, notify
      if not ok then
        error(err)
      end
    end)
  end

  check('build response determines status and prevents duplicate requests', function()
    local client, calls = fixture()
    eq('idle', tex.build_status().phase)
    eq(true, tex.build())
    eq('requested', tex.build_status().phase)
    eq(false, tex.build())
    eq(1, #calls)
    manager.progress(client, { token = 1, value = { kind = 'begin', title = 'Building' } })
    eq('running', tex.build_status().phase)
    calls[1].callback(nil, { status = 0 })
    manager.progress(client, { token = 1, value = { kind = 'end' } })
    eq('succeeded', tex.build_status().phase)
    eq(0, tex.build_status().result)
    eq(true, tex.build_status().elapsed >= 0)
  end)

  check('all result codes and failures are reflected in status', function()
    local _, calls = fixture()
    for code, phase in pairs({ [0] = 'succeeded', [1] = 'failed', [2] = 'failed_to_start', [3] = 'cancelled' }) do
      eq(true, tex.build())
      calls[#calls].callback(nil, { status = code })
      eq(phase, tex.build_status().phase)
    end
    eq(true, tex.build())
    calls[#calls].callback({ message = 'connection failed' })
    eq('connection failed', tex.build_status().error)
    eq(true, tex.build())
    calls[#calls].callback(nil, nil)
    eq('unknown', tex.build_status().phase)
    eq(nil, tex.build_status().error)
  end)

  check('automatic builds use native LspProgress without replacing handlers', function()
    local client = fixture()
    vim.lsp.get_client_by_id = function()
      return client
    end
    manager.attach(client)
    local progress_handler = vim.lsp.handlers['$/progress']
    vim.api.nvim_exec_autocmds('LspProgress', {
      pattern = 'begin',
      data = {
        client_id = client.id,
        params = { token = 10, value = { kind = 'begin', title = 'Building', message = 'file:///tmp/main.tex' } },
      },
    })
    eq('running', tex.build_status().phase)
    eq('file:///tmp/main.tex', tex.build_status().uri)
    manager.progress(client, { token = 11, value = { kind = 'end' } })
    eq('running', tex.build_status().phase)
    manager.progress(client, { token = 10, value = { kind = 'end' } })
    eq('finished', tex.build_status().phase)
    eq(progress_handler, vim.lsp.handlers['$/progress'])
  end)

  check('dependency parsing progress does not become a build', function()
    local client = fixture()
    manager.progress(client, { token = 11, value = { kind = 'begin', title = 'Parsing Dependencies.' } })
    manager.progress(client, { token = 11, value = { kind = 'end' } })
    eq('idle', tex.build_status().phase)
  end)

  check('cancel command reaches texlab and waits for cancellation', function()
    local client, calls = fixture()
    eq(true, tex.build())
    eq(true, tex.cancel_build())
    eq('workspace/executeCommand', calls[2].method)
    eq('texlab.cancelBuild', calls[2].params.command)
    calls[2].callback(nil, nil)
    eq('cancelling', tex.build_status().phase)
    calls[1].callback(nil, { status = 3 })
    eq('cancelled', tex.build_status().phase)
    eq(false, manager.active(client))
  end)

  check('late cancellation acknowledgements do not affect a newer build', function()
    local _, calls = fixture()
    tex.build()
    tex.cancel_build()
    calls[1].callback(nil, { status = 0 })
    tex.build()
    calls[2].callback(nil, nil)
    eq('requested', tex.build_status().phase)
  end)

  check('cancel all addresses every texlab client', function()
    local first, first_calls = fixture()
    local second, second_calls = fixture()
    vim.lsp.get_clients = function()
      return { first, second }
    end
    eq(true, tex.cancel_all_builds())
    eq('texlab.cancelBuild', first_calls[1].params.command)
    eq('texlab.cancelBuild', second_calls[1].params.command)
  end)

  check('unsupported commands and rejected requests return actionable errors', function()
    local client, calls = fixture()
    client.server_capabilities.executeCommandProvider.commands = {}
    eq(false, tex.cancel_build())
    eq(0, #calls)
    client.server_capabilities = {}
    client.request = function()
      return false
    end
    eq(false, tex.build())
    eq('failed', tex.build_status().phase)
    eq(false, tex.cancel_build())
    eq(false, tex.cancel_all_builds())
  end)

  check('on-save changes preserve settings and send configuration notifications', function()
    local client = fixture()
    client.settings.texlab.build.executable = 'tectonic'
    eq({ true, true }, { tex.build_on_save() })
    eq('workspace/didChangeConfiguration', client.notification.method)
    eq('tectonic', client.notification.params.settings.texlab.build.executable)
    eq({ true, false }, { tex.build_on_save() })
    eq({ true, true }, { tex.build_on_save(true) })
    eq({ true, false }, { tex.build_on_save(false) })
    client.notify = function()
      return false
    end
    eq(false, tex.build_on_save(true))
    eq(false, client.settings.texlab.build.onSave)
  end)

  check('saving with on-save enabled does not queue a second explicit build', function()
    local client, calls, bufnr, path = fixture()
    client.settings.texlab.build.onSave = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'changed' })
    eq(true, tex.build())
    eq({ 'changed' }, vim.fn.readfile(path))
    eq(0, #calls)
    eq('requested', tex.build_status().phase)
    vim.fn.delete(path)
  end)

  check('commands and mappings reach the new actions', function()
    local _, calls = fixture()
    tex.setup()
    vim.cmd.TexToolsBuildOnSave('on')
    eq(true, tex.build_status().on_save)
    vim.cmd.TexToolsBuildOnSave('off')
    vim.cmd.TexToolsBuild()
    vim.cmd.TexToolsCancelBuild()
    eq('texlab.cancelBuild', calls[2].params.command)
    eq('<Plug>(TexToolsCancelBuild)', vim.fn.maparg(',lk', 'n'))
    eq('<Plug>(TexToolsCancelAllBuilds)', vim.fn.maparg(',lK', 'n'))
    eq('<Plug>(TexToolsBuildStatus)', vim.fn.maparg(',lg', 'n'))
    vim.cmd.TexToolsBuildStatus()
  end)

  check('missing clients fail without changing editor state', function()
    h.buffer('source')
    vim.lsp.get_clients = function()
      return {}
    end
    eq(false, tex.cancel_build())
    eq(false, tex.cancel_all_builds())
    eq(nil, tex.build_status())
    eq(false, tex.build_on_save(true))
    eq('source', h.content())
  end)
end
