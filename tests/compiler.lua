return function(h)
  local tex, manager = require('tex-tools'), require('tex-tools.build')
  local eq = h.eq
  local directory, profiles
  local function check(name, fn)
    h.test('compiler profiles: ' .. name, function()
      local get_clients, notify = vim.lsp.get_clients, vim.notify
      directory = vim.fn.tempname() .. ' project'
      vim.fn.mkdir(directory .. '/bin with spaces', 'p')
      profiles = {}
      for _, name in ipairs({ 'latexmk', 'tectonic' }) do
        local executable = directory .. '/bin with spaces/' .. name
        vim.fn.writefile({ '#!/bin/sh', 'exit 0' }, executable)
        vim.fn.setfperm(executable, 'rwxr-xr-x')
        profiles[name] =
          { executable = executable, args = name == 'latexmk' and { '-pdf', '%f' } or { '-X', 'compile', '%f' } }
      end
      tex.setup({ build = { profiles = profiles } })
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.notify = get_clients, notify
      vim.fn.delete(directory, 'rf')
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function fixture(name)
    local bufnr = h.buffer('\\documentclass{article}')
    local path = directory .. '/' .. (name or 'main') .. '.tex'
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.fn.writefile({ '\\documentclass{article}' }, path)
    vim.bo.modified = false
    local client = {
      id = bufnr + 40000,
      name = 'texlab',
      settings = {
        unrelated = { enabled = true },
        texlab = {
          build = {
            executable = 'custom-wrapper',
            args = { 'old', 'arguments', 'must', 'disappear' },
            onSave = true,
            forwardSearchAfter = true,
          },
          forwardSearch = { executable = 'viewer', args = { '%p', '%l' } },
          chktex = { onEdit = false },
        },
      },
      handlers = {},
    }
    local notifications = {}
    function client:notify(method, params)
      notifications[#notifications + 1] = { method = method, params = params }
      return true
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    return client, notifications, bufnr
  end

  check('query keeps LSP defaults and does not send configuration or modify buffers', function()
    local client, notifications = fixture()
    local original = client.settings
    local ok, snapshot = tex.compiler()
    eq(true, ok)
    eq(nil, snapshot.profile)
    eq('custom-wrapper', snapshot.executable)
    eq({ 'latexmk', 'tectonic' }, snapshot.profiles)
    eq(original, client.settings)
    eq(0, #notifications)
    snapshot.args[1] = 'mutated'
    snapshot.profiles[1] = 'mutated'
    eq('old', client.settings.texlab.build.args[1])
    eq({ 'latexmk', 'tectonic' }, require('tex-tools.compiler').names())
    eq('\\documentclass{article}', h.content())
    client.settings = nil
    eq('latexmk', select(2, tex.compiler()).executable)
    eq(nil, client.settings)
  end)

  check('switch replaces argument lists, preserves shared settings and records status', function()
    local client, notifications = fixture()
    local original = vim.deepcopy(client.settings)
    local ok, snapshot = tex.compiler('tectonic')
    eq(true, ok)
    eq('tectonic', snapshot.profile)
    eq(profiles.tectonic.executable, snapshot.executable)
    eq('workspace/didChangeConfiguration', notifications[1].method)
    eq(client.settings, notifications[1].params.settings)
    eq(profiles.tectonic.args, client.settings.texlab.build.args)
    eq(true, client.settings.texlab.build.onSave)
    eq(true, client.settings.texlab.build.forwardSearchAfter)
    eq(original.texlab.forwardSearch, client.settings.texlab.forwardSearch)
    eq(original.texlab.chktex, client.settings.texlab.chktex)
    eq(original.unrelated, client.settings.unrelated)
    eq('tectonic', tex.build_status().profile)
    eq(profiles.tectonic.executable, tex.build_status().compiler)
    eq('idle', tex.build_status().phase)
    client.settings.texlab.build.args[1] = 'local edit'
    eq('-X', require('tex-tools.config').options.build.profiles.tectonic.args[1])
    eq(nil, tex.build_status().profile)
  end)

  check('profile paths and filename are replaced and omitted overrides are cleared', function()
    profiles.latexmk.auxDirectory = 'aux'
    profiles.latexmk.logDirectory = 'logs'
    profiles.latexmk.pdfDirectory = 'pdf'
    profiles.latexmk.filename = 'result.pdf'
    tex.setup({ build = { profiles = profiles } })
    local client = fixture()
    eq(true, tex.compiler('latexmk'))
    eq('logs', client.settings.texlab.build.logDirectory)
    eq('result.pdf', client.settings.texlab.build.filename)
    eq(true, tex.compiler('tectonic'))
    for _, field in ipairs({ 'auxDirectory', 'logDirectory', 'pdfDirectory', 'filename' }) do
      eq(nil, client.settings.texlab.build[field])
    end
    local resolved = assert(require('tex-tools.project').resolve(client))
    eq(directory, resolved.log_dir)
    eq('main.pdf', resolved.pdf_name)
  end)

  check('toggle starts from unmatched settings, cycles deterministically and handles one profile', function()
    fixture()
    eq('latexmk', select(2, tex.compiler('toggle')).profile)
    eq('tectonic', select(2, tex.compiler('toggle')).profile)
    eq('latexmk', select(2, tex.compiler('toggle')).profile)
    tex.setup({ build = { profiles = { tectonic = profiles.tectonic } } })
    eq('tectonic', select(2, tex.compiler('toggle')).profile)
    eq('tectonic', select(2, tex.compiler('toggle')).profile)
  end)

  check('recognizes preconfigured profiles and honors duplicate aliases and external changes', function()
    local client = fixture()
    client.settings.texlab.build = vim.deepcopy(profiles.tectonic)
    client.settings.texlab.build.onSave = true
    client.settings.texlab.build.filename = vim.NIL
    eq('tectonic', tex.build_status().profile)
    eq('latexmk', select(2, tex.compiler('toggle')).profile)
    profiles.alias = vim.deepcopy(profiles.latexmk)
    tex.setup({ build = { profiles = profiles } })
    eq('alias', select(2, tex.compiler('alias')).profile)
    eq('alias', tex.build_status().profile)
    eq('latexmk', select(2, tex.compiler('latexmk')).profile)
    client.settings.texlab.build = vim.deepcopy(profiles.tectonic)
    eq('tectonic', tex.build_status().profile)
    tex.setup()
    eq(nil, tex.build_status().profile)
  end)

  check('active manual/automatic builds and cleanup prevent switching, while query still works', function()
    local client, notifications = fixture()
    manager.begin(client, 'file:///main.tex')
    eq(false, tex.compiler('tectonic'))
    eq(true, tex.compiler())
    manager.finish(client, manager.state(client).generation, 0)
    manager.progress(client, { token = 1, value = { kind = 'begin', title = 'Building' } })
    eq(false, tex.compiler('toggle'))
    manager.progress(client, { token = 1, value = { kind = 'end' } })
    manager.state(client).cleaning = true
    eq(false, tex.compiler('latexmk'))
    eq(true, tex.compiler())
    eq(0, #notifications)
    manager.state(client).cleaning = nil
    eq(true, tex.compiler('tectonic'))
  end)

  check('unknown profiles, missing/non-executable compilers and empty configuration do not mutate settings', function()
    local client, notifications = fixture()
    local settings = client.settings
    eq(false, tex.compiler('missing'))
    profiles.tectonic.executable = directory .. '/nonexistent'
    tex.setup({ build = { profiles = profiles } })
    eq(false, tex.compiler('tectonic'))
    vim.fn.writefile({ 'not executable' }, profiles.tectonic.executable)
    eq(false, tex.compiler('tectonic'))
    tex.setup()
    local ok, err = tex.compiler('toggle')
    eq(false, ok)
    eq(true, err:find('build.profiles', 1, true) ~= nil)
    eq(settings, client.settings)
    eq(0, #notifications)
    eq(true, tex.compiler())
  end)

  check('notification rejection or failure restores exact settings and the selected profile', function()
    local client = fixture()
    eq(true, tex.compiler('latexmk'))
    local settings = client.settings
    client.notify = function()
      return false
    end
    eq(false, tex.compiler('tectonic'))
    eq(true, rawequal(settings, client.settings))
    eq('latexmk', tex.build_status().profile)
    client.notify = function()
      error('transport failure')
    end
    local ok, err = tex.compiler('tectonic')
    eq(false, ok)
    eq(true, err:find('transport failure', 1, true) ~= nil)
    eq(true, rawequal(settings, client.settings))
    client.settings = nil
    eq(false, tex.compiler('tectonic'))
    eq(nil, client.settings)
  end)

  check('shared buffers switch together and independent clients keep their own settings', function()
    local first, first_notifications, first_buf = fixture()
    local original = first.settings
    local second, second_notifications = fixture('other')
    -- Neovim clients may share the original LSP config table.
    second.settings = original
    local shared_buf = h.buffer('child')
    vim.lsp.get_clients = function(opts)
      if opts.bufnr == first_buf or opts.bufnr == shared_buf then
        return { first }
      end
      return { second }
    end
    eq(true, tex.compiler('tectonic'))
    vim.api.nvim_set_current_buf(first_buf)
    eq('tectonic', select(2, tex.compiler()).profile)
    eq(1, #first_notifications)
    eq(0, #second_notifications)
    eq(true, rawequal(original, second.settings))
    eq('custom-wrapper', second.settings.texlab.build.executable)
  end)

  check('no attached client returns an actionable error', function()
    h.buffer('source')
    vim.lsp.get_clients = function()
      return {}
    end
    local ok, err = tex.compiler('tectonic')
    eq(false, ok)
    eq(true, err:find('No texlab client', 1, true) ~= nil)
    eq(false, tex.compiler())
  end)

  check('invalid profile configuration is rejected without replacing the last valid setup', function()
    local original = require('tex-tools.config').options
    for _, invalid in ipairs({
      false,
      { toggle = profiles.tectonic },
      { ['bad name'] = profiles.tectonic },
      { [1] = profiles.tectonic },
      { broken = {} },
      { broken = { executable = '', args = {} } },
      { broken = { executable = 'program', args = { [2] = '%f' } } },
      { broken = { executable = 'program', args = { 1 } } },
      { broken = { executable = 'program', args = {}, onSave = true } },
      { broken = { executable = 'program', args = {}, logDirectory = false } },
      { broken = { executable = 'program', args = {}, filename = '../main.pdf' } },
      { broken = { executable = 'program', args = {}, filename = '..' } },
      { broken = { executable = 'program', args = { '\0' } } },
    }) do
      eq(false, pcall(tex.setup, { build = { profiles = invalid } }))
      eq(true, rawequal(original, require('tex-tools.config').options))
    end
  end)
end
