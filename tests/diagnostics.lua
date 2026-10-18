return function(h)
  local tex, eq = require('tex-tools'), h.eq
  local sync = require('tex-tools.diagnostics')
  local directory, client, bufnr, notifications, destination, accepted
  local function fixture()
    directory = vim.fn.tempname() .. ' diagnostics'
    vim.fn.mkdir(directory, 'p')
    bufnr = h.buffer('\\documentclass{article}')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/main.tex')
    vim.fn.writefile({ '\\documentclass{article}' }, directory .. '/main.tex')
    vim.fn.writefile({ '$out_dir="build";' }, directory .. '/.latexmkrc')
    vim.bo.modified = false
    notifications, destination, accepted = {}, 'build', true
    client = {
      id = bufnr + 89000,
      name = 'texlab',
      initialized = true,
      attached_buffers = { [bufnr] = true },
      config = { root_dir = directory },
      handlers = {},
      settings = {
        other = { preserved = true },
        texlab = {
          build = { executable = 'latexmk', args = { '-pdf', '%f' }, onSave = true },
          forwardSearch = { executable = 'viewer', args = { '%p' } },
        },
      },
    }
    function client:notify(method, params)
      notifications[#notifications + 1] = { method = method, params = params }
      return accepted
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.lsp.get_client_by_id = function(id)
      return id == client.id and client or nil
    end
    local executable = vim.fn.executable
    vim.fn.executable = function(name)
      return name == 'latexmk' and 1 or executable(name)
    end
    vim.system = function()
      return {
        wait = function()
          return {
            code = 0,
            stdout = ("Latexmk: Cwd: '%s'\nLatexmk: Normalized aux dir, out dir, out2 dir:\n  '%s', '%s', '%s'\nLatexmk: Base name of generated files:\n  'main'\n"):format(
              directory,
              destination,
              destination,
              destination
            ),
          }
        end,
      }
    end
  end
  local function check(name, fn)
    h.test('texlab diagnostics: ' .. name, function()
      local clients, by_id, executable, system, notify =
        vim.lsp.get_clients, vim.lsp.get_client_by_id, vim.fn.executable, vim.system, vim.notify
      local ok, err = xpcall(function()
        fixture()
        fn()
      end, debug.traceback)
      -- Finish coalesced callbacks while this fixture's client is still live.
      vim.wait(1, function()
        return false
      end, 1)
      vim.lsp.get_clients, vim.lsp.get_client_by_id, vim.fn.executable, vim.system, vim.notify =
        clients, by_id, executable, system, notify
      if client then
        sync.forget(client)
      end
      if directory then
        vim.fn.delete(directory, 'rf')
      end
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  check('synchronizes discovered logs without losing build or viewer settings', function()
    local before = vim.deepcopy(client.settings)
    eq(true, sync.sync(client, bufnr))
    eq(directory .. '/build', client.settings.texlab.build.logDirectory)
    eq(nil, before.texlab.build.logDirectory)
    eq(before.texlab.build.args, client.settings.texlab.build.args)
    eq(true, client.settings.texlab.build.onSave)
    eq(before.other, client.settings.other)
    eq(before.texlab.forwardSearch, client.settings.texlab.forwardSearch)
    eq('workspace/didChangeConfiguration', notifications[1].method)
    eq(client.settings, notifications[1].params.settings)
    eq(true, sync.sync(client, bufnr))
    eq(1, #notifications)
  end)
  check('rc changes replace managed paths and do not become fixed overrides', function()
    eq(true, sync.sync(client, bufnr))
    destination = 'new output'
    vim.fn.writefile({ '$out_dir="new output";' }, directory .. '/.latexmkrc')
    eq(true, sync.sync(client, bufnr))
    eq(directory .. '/new output', client.settings.texlab.build.logDirectory)
    eq(directory .. '/new output/main.log', tex.project_info().log_file)
    eq(nil, sync.build_settings(client).logDirectory)
    eq(2, #notifications)
  end)
  check('explicit paths are preserved, including a later user override', function()
    client.settings.texlab.build.logDirectory = 'explicit logs'
    eq(true, sync.sync(client, bufnr))
    eq(0, #notifications)
    client.settings.texlab.build.logDirectory = nil
    eq(true, sync.sync(client, bufnr))
    client.settings.texlab.build.logDirectory = 'user changed logs'
    eq(true, sync.sync(client, bufnr))
    eq(1, #notifications)
    eq('user changed logs', sync.build_settings(client).logDirectory)
  end)
  check('backend changes clear only the owned directory', function()
    eq(true, sync.sync(client, bufnr))
    client.settings.texlab.build.executable = 'tectonic'
    eq(true, sync.sync(client, bufnr))
    eq(nil, client.settings.texlab.build.logDirectory)
    eq(2, #notifications)
    client.settings.texlab.build.logDirectory = 'explicit tectonic logs'
    eq(true, sync.sync(client, bufnr))
    eq(2, #notifications)
  end)
  check('managed directories do not hide compiler profile identity', function()
    tex.setup({ build = { profiles = { latexmk = { executable = 'latexmk', args = { '-pdf', '%f' } } } } })
    eq(true, sync.sync(client, bufnr))
    eq('latexmk', require('tex-tools.compiler').snapshot(client).profile)
  end)
  check('rejected notifications restore settings and allow retry', function()
    local before = client.settings
    accepted = false
    eq(false, sync.sync(client, bufnr))
    eq(before, client.settings)
    eq(nil, sync.build_settings(client).logDirectory)
    accepted = true
    eq(true, sync.sync(client, bufnr))
    eq(directory .. '/build', client.settings.texlab.build.logDirectory)
  end)
  check('scheduling coalesces events and resolves the initiating hidden buffer', function()
    sync.schedule(client, bufnr)
    sync.schedule(client, bufnr)
    h.buffer('outside', 'lua')
    assert(vim.wait(1000, function()
      return #notifications == 1
    end, 10))
    eq(directory .. '/build', client.settings.texlab.build.logDirectory)
  end)
  check('status polling never perpetually reschedules directory discovery', function()
    local schedule, queued = vim.schedule, {}
    vim.schedule = function(callback)
      queued[#queued + 1] = callback
    end
    local ok, err = pcall(function()
      for _ = 1, 20 do
        tex.build_status()
      end
      eq(1, #queued)
    end)
    vim.schedule = schedule
    for _, callback in ipairs(queued) do
      callback()
    end
    if not ok then
      error(err)
    end
    eq(1, #notifications)
  end)
  check('saving rc files updates the active client without requiring another TeX save', function()
    sync.attach(client, bufnr)
    assert(vim.wait(1000, function()
      return #notifications == 1
    end, 10))
    destination = 'new directory'
    vim.cmd.edit(vim.fn.fnameescape(directory .. '/.latexmkrc'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '$out_dir="new directory";' })
    vim.cmd.write()
    assert(vim.wait(1000, function()
      return #notifications == 2
    end, 10))
    eq(directory .. '/new directory', client.settings.texlab.build.logDirectory)
  end)
end
