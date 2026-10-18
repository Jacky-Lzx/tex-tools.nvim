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

  check('buffer commands show current settings, switch, complete names and report errors', function()
    local client, notifications = fixture()
    local messages = {}
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
    vim.cmd.TexToolsCompiler()
    eq(true, messages[#messages][1]:find('custom-wrapper (texlab settings)', 1, true) ~= nil)
    eq(0, #notifications)
    eq({ 'tectonic' }, vim.fn.getcompletion('TexToolsCompiler te', 'cmdline'))
    eq({ 'toggle' }, vim.fn.getcompletion('TexToolsCompiler tog', 'cmdline'))
    eq({ 'latexmk', 'tectonic', 'toggle' }, vim.fn.getcompletion('TexToolsCompiler ', 'cmdline'))
    vim.cmd.TexToolsCompiler('tectonic')
    eq('tectonic', tex.build_status().profile)
    eq(true, messages[#messages][1]:find('tectonic (', 1, true) ~= nil)
    vim.cmd.TexToolsBuildStatus()
    eq(true, messages[#messages][1]:find('[profile: tectonic]', 1, true) ~= nil)
    vim.cmd.TexToolsCompiler('toggle')
    eq('latexmk', tex.build_status().profile)
    vim.cmd.TexToolsCompiler('missing')
    eq(vim.log.levels.WARN, messages[#messages][2])
    eq('latexmk', tex.build_status().profile)
    eq(2, #notifications)
    manager.state(client).cleaning = true
    vim.cmd.TexToolsCompiler('tectonic')
    eq(vim.log.levels.WARN, messages[#messages][2])
    eq(2, #notifications)
  end)

  check('switching changes log discovery and chooses the matching cleanup backend', function()
    local client = fixture()
    profiles.latexmk.args = { '-pdf', '-outdir=latexmk-out', '%f' }
    profiles.latexmk.auxDirectory = 'latexmk-out'
    profiles.latexmk.logDirectory = 'latexmk-out'
    profiles.latexmk.pdfDirectory = 'latexmk-out'
    profiles.tectonic.args = { '-X', 'compile', '%f', '--outdir', 'tectonic-out' }
    profiles.tectonic.auxDirectory = 'tectonic-out'
    profiles.tectonic.logDirectory = 'tectonic-out'
    profiles.tectonic.pdfDirectory = 'tectonic-out'
    tex.setup({ build = { profiles = profiles } })
    local source = vim.api.nvim_get_current_buf()
    for _, path in ipairs({ 'latexmk-out', 'tectonic-out' }) do
      vim.fn.mkdir(directory .. '/' .. path)
      vim.fn.writefile({ path .. ' log' }, directory .. '/' .. path .. '/main.log')
      vim.fn.writefile({ 'PDF' }, directory .. '/' .. path .. '/main.pdf')
    end
    local calls = {}
    function client:request(method, params, callback)
      calls[#calls + 1] = { method, params }
      callback(nil)
      return true, #calls
    end
    local ok, err = xpcall(function()
      eq(true, tex.compiler('latexmk'))
      eq({ true, directory .. '/latexmk-out/main.log' }, { tex.build_log() })
      vim.cmd.close()
      vim.api.nvim_set_current_buf(source)
      eq(true, tex.clean())
      eq('texlab.cleanAuxiliary', calls[1][2].command)
      eq(true, tex.compiler('tectonic'))
      eq({ true, directory .. '/tectonic-out/main.log' }, { tex.build_log() })
      vim.cmd.close()
      vim.api.nvim_set_current_buf(source)
      eq({ true, 1 }, { tex.clean() })
      eq(1, #calls)
      eq(0, vim.fn.filereadable(directory .. '/tectonic-out/main.log'))
      eq(1, vim.fn.filereadable(directory .. '/latexmk-out/main.log'))
      eq({ true, 1 }, { tex.clean(true) })
      eq(0, vim.fn.filereadable(directory .. '/tectonic-out/main.pdf'))
      eq(1, vim.fn.filereadable(directory .. '/latexmk-out/main.pdf'))
    end, debug.traceback)
    vim.cmd('silent! only!')
    if not ok then
      error(err)
    end
  end)

  check('real LSP configuration pull reads each profile and clears old overrides before building', function()
    local bufnr = h.buffer('\\documentclass{article}')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/main.tex')
    vim.fn.writefile({ '\\documentclass{article}' }, directory .. '/main.tex')
    vim.bo.modified = false
    vim.notify = function() end
    profiles.latexmk.logDirectory = 'old-logs'
    profiles.latexmk.filename = 'old.pdf'
    tex.setup({ build = { profiles = profiles } })
    local id = vim.lsp.start({
      name = 'texlab',
      root_dir = directory,
      settings = {
        texlab = { build = { onSave = false, forwardSearchAfter = true }, forwardSearch = { executable = 'viewer' } },
      },
      handlers = { ['window/logMessage'] = function() end },
      cmd_env = { TEX_TOOLS_FIXTURE_PULL = '1' },
      cmd = {
        vim.fn.exepath('nvim'),
        '--clean',
        '--headless',
        '-i',
        'NONE',
        '-l',
        vim.fn.getcwd() .. '/tests/fixtures/texlab.lua',
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
      for _, name in ipairs({ 'latexmk', 'tectonic' }) do
        eq(true, tex.compiler(name))
        local response, rpc_error
        eq(
          true,
          client:request('tex-tools/fixtureSettings', {}, function(error, result)
            rpc_error, response = error, result
          end, bufnr)
        )
        eq(
          true,
          vim.wait(3000, function()
            return response ~= nil or rpc_error ~= nil
          end)
        )
        eq(nil, rpc_error)
        eq(profiles[name].executable, response.texlab.build.executable)
        eq(profiles[name].args, response.texlab.build.args)
        eq(profiles[name].logDirectory, response.texlab.build.logDirectory)
        eq(profiles[name].filename, response.texlab.build.filename)
        eq(false, response.texlab.build.onSave)
        eq(true, response.texlab.build.forwardSearchAfter)
        eq('viewer', response.texlab.forwardSearch.executable)
        eq(true, tex.build())
        eq(
          true,
          vim.wait(3000, function()
            return manager.snapshot(client).phase == 'failed'
          end)
        )
        eq(name, tex.build_status().profile)
        eq({ 'compiler output: line one', 'compiler output: line two' }, manager.state(client).output_lines)
      end
    end, debug.traceback)
    client:stop(true)
    vim.wait(1000, function()
      return vim.lsp.get_client_by_id(id) == nil
    end)
    if not ok then
      error(err)
    end
  end)
end
