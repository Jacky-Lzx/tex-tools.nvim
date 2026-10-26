return function(h)
  local tex, config, lsp = require('tex-tools'), require('tex-tools.config'), require('tex-tools.lsp')
  local eq, test = h.eq, h.test
  local next_id = 45000
  local function check(name, fn)
    test('LSP backends: ' .. name, function()
      local get_clients, notify = vim.lsp.get_clients, vim.notify
      local ok, err = xpcall(function()
        config.setup({ lsp = 'latex-lsp' })
        fn()
      end, debug.traceback)
      vim.lsp.get_clients, vim.notify = get_clients, notify
      config.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function fixture(options)
    local bufnr = h.buffer('\\documentclass{article}\n\\begin{document}中文 text\\end{document}')
    next_id = next_id + 1
    local path = '/private/tmp/tex-tools-backend-' .. next_id .. '.tex'
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.bo.modified = false
    local calls = {}
    local client = {
      id = next_id,
      name = 'latex_lsp',
      offset_encoding = 'utf-16',
      handlers = {},
      config = { root_dir = '/private/tmp', init_options = options or {} },
      settings = {},
      server_capabilities = {
        executeCommandProvider = {
          commands = {
            'latex.build',
            'latex.cancelBuild',
            'latex.buildStatus',
            'latex.cleanAuxiliary',
            'latex.cleanArtifacts',
            'latex.forwardSearch',
            'latex.inverseSearch',
          },
        },
      },
      response = { status = 'idle', rootUri = vim.uri_from_fname(path) },
    }
    function client:request(method, params, callback, target)
      calls[#calls + 1] = { method = method, params = params, callback = callback, target = target }
      return not self.reject, #calls
    end
    function client:request_sync(method, params, _, target)
      calls[#calls + 1] = { method = method, params = params, target = target }
      if self.sync_error then
        return { err = { message = self.sync_error } }
      end
      return { result = vim.deepcopy(self.response) }
    end
    function client:notify(method, params)
      self.notification = { method = method, params = params }
      return not self.reject
    end
    vim.lsp.get_clients = function(filter)
      if not filter.name then
        return { { name = 'texlab' }, client }
      end
      return {}
    end
    vim.notify = function() end
    return client, calls, bufnr, path
  end

  check('selection accepts canonical and hyphenated client names without texlab fallback', function()
    local client = fixture()
    eq(client, lsp.client())
    client.name = 'latex-lsp'
    eq(client, lsp.client())
    config.setup()
    eq(nil, lsp.client())
    config.setup({ lsp = 'latex-lsp' })
    client.name = 'other'
    local selected, err = lsp.client()
    eq(nil, selected)
    eq('No latex-lsp client attached to this buffer', err)
    eq(false, pcall(config.setup, { lsp = 'unknown' }))
  end)

  check('failed setup preserves backend and profile schema', function()
    fixture()
    local fields = config.profile_fields
    eq(false, pcall(config.setup, { lsp = 'texlab', build = { profiles = { invalid = {} } } }))
    eq('latex-lsp', lsp.backend())
    eq(fields, config.profile_fields)
  end)

  check('old texlab diagnostics listeners do not query the new backend', function()
    local client, calls = fixture()
    client.name, client.initialized = 'texlab', true
    eq(true, require('tex-tools.diagnostics').sync(client, vim.api.nvim_get_current_buf()))
    eq(0, #calls)
  end)

  check('build and cancellation use advertised latex commands', function()
    local client, calls, bufnr = fixture()
    eq(true, tex.build())
    eq('workspace/executeCommand', calls[1].method)
    eq({ command = 'latex.build', arguments = { vim.uri_from_bufnr(bufnr) } }, calls[1].params)
    eq(true, tex.cancel_build())
    eq('latex.cancelBuild', calls[2].params.command)
    eq({ vim.uri_from_bufnr(bufnr) }, calls[2].params.arguments)
    eq(true, tex.cancel_all_builds())
    eq({}, calls[3].params.arguments)
    client.reject = true
    eq(false, tex.build())
    client.reject = false
    client.server_capabilities.executeCommandProvider.commands = {}
    eq(false, tex.build())
    eq(4, #calls)
  end)

  check('unsaved buffers fail before sending commands', function()
    local _, calls = fixture()
    vim.api.nvim_buf_set_name(0, '')
    eq(false, tex.build())
    eq(false, tex.clean())
    eq(false, tex.forward_search())
    eq(0, #calls)
  end)

  check('status and artifact paths come from server including failures and idle', function()
    local client, calls = fixture()
    local status = assert(tex.build_status())
    eq('idle', status.phase)
    eq('latex.buildStatus', calls[1].params.command)
    local info = assert(tex.project_info())
    eq(nil, info.pdf_file)
    eq(false, tex.view())
    eq(false, tex.build_log())
    client.response = {
      status = 'success',
      rootUri = 'file:///private/tmp/server-root.tex',
      pdfUri = 'file:///private/tmp/final/custom.pdf',
      logUri = 'file:///private/tmp/aux/custom.log',
      executable = 'xelatex',
      durationMs = 250,
      stale = false,
    }
    status = assert(tex.build_status())
    eq('success', status.phase)
    eq(0.25, status.elapsed)
    eq('xelatex', status.compiler)
    status.phase = 'caller mutation'
    eq('success', tex.build_status().phase)
    info = assert(tex.project_info())
    eq('/private/tmp/server-root.tex', info.main_file)
    eq('/private/tmp/final/custom.pdf', info.pdf_file)
    eq('/private/tmp/aux/custom.log', info.log_file)
    eq('latex-lsp', info.artifact_source)
    client.sync_error = 'ambiguous root'
    local value, err = tex.build_status()
    eq(nil, value)
    eq('ambiguous root', err)
  end)

  check('configuration preserves init options and wrapped settings with rollback', function()
    local client = fixture({ build = { executable = 'xelatex', onSave = true }, diagnostics = { enabled = false } })
    client.settings = { latex = { formatting = { formatter = 'latexindent' } }, unrelated = { retained = true } }
    eq({ true, false }, { tex.build_on_save(false) })
    eq('xelatex', client.settings.latex.build.executable)
    eq(false, client.settings.latex.diagnostics.enabled)
    eq('latexindent', client.settings.latex.formatting.formatter)
    eq(true, client.settings.unrelated.retained)
    local previous = vim.deepcopy(client.settings)
    client.reject = true
    eq(false, tex.build_on_save(true))
    eq(previous, client.settings)
    client.reject = false
    eq(true, tex.build_on_save())
    eq(true, client.settings.latex.build.onSave)
    local ok, main = tex.main_file('selected.tex')
    eq(true, ok)
    eq(vim.uri_to_fname(client.response.rootUri), main)
    eq('selected.tex', client.settings.latex.build.rootFile)
    eq(true, tex.main_file(false))
    eq(vim.NIL, client.settings.latex.build.rootFile)
  end)

  check('native compiler profiles replace only native fields', function()
    local client = fixture({ build = { timeoutSeconds = 77, onSave = true, engine = 'xelatex' } })
    config.setup({
      lsp = 'latex-lsp',
      build = {
        profiles = {
          direct = { executable = 'xelatex', arguments = { '%f' }, outputDirectory = 'output' },
          latexmk = { executable = 'latexmk' },
        },
      },
    })
    local ok, snapshot = tex.compiler('direct')
    eq(true, ok)
    eq('direct', snapshot.profile)
    eq({ '%f' }, client.settings.build.arguments)
    eq('output', client.settings.build.outputDirectory)
    eq(vim.NIL, client.settings.build.engine)
    eq(nil, client.settings.texlab)
    eq(77, client.settings.build.timeoutSeconds)
    eq(true, client.settings.build.onSave)
    eq(true, tex.compiler('toggle'))
    local _, current = tex.compiler()
    eq('latexmk', current.profile)
  end)

  check('clean delegates all artifact safety and result errors to server', function()
    local _, calls = fixture()
    eq(true, tex.clean())
    eq('latex.cleanAuxiliary', calls[1].params.command)
    eq(true, tex.clean(true))
    eq('latex.cleanArtifacts', calls[2].params.command)
    local messages = {}
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
    calls[2].callback(nil, { errors = { 'permission denied' } })
    eq(vim.log.levels.WARN, messages[1][2])
    calls[1].callback({ message = 'active build' })
    eq('active build', messages[2][1])
  end)

  check('build notifications preserve handlers and native progress', function()
    local client = fixture()
    local seen = 0
    client.handlers['latex/buildFinished'] = function()
      seen = seen + 1
    end
    local progress = vim.lsp.handlers['$/progress']
    eq(client, lsp.client())
    local wrapper = client.handlers['latex/buildFinished']
    eq(client, lsp.client())
    eq(wrapper, client.handlers['latex/buildFinished'])
    client.handlers['latex/buildStarted'](nil, { rootUri = client.response.rootUri })
    wrapper(nil, { status = 'success', output = 'compiler output\n' })
    eq(1, seen)
    eq({ 'compiler output' }, require('tex-tools.build').state(client).output_lines)
    eq(progress, vim.lsp.handlers['$/progress'])
    eq(nil, client.handlers['window/logMessage'])
  end)

  check('forward search uses server coordinates and UTF-16 positions', function()
    local client, calls = fixture()
    vim.api.nvim_win_set_cursor(0, { 2, #'\\begin{document}中文 ' })
    local show = require('tex-tools.viewer').show_location
    local received
    require('tex-tools.viewer').show_location = function(source, result)
      eq(client, source)
      received = result
      return true
    end
    local ok, err = xpcall(function()
      eq(true, tex.forward_search())
      eq('latex.forwardSearch', calls[1].params.command)
      eq({ line = 1, character = #'\\begin{document}' + 3 }, calls[1].params.arguments[1].position)
      local result = { pdfUri = 'file:///private/tmp/output.pdf', locations = { { page = 4, x = 25, y = 80 } } }
      calls[1].callback(nil, result)
      eq(result, received)
      eq(true, tex.inverse_search_position(4, 25, 80))
      eq('latex.inverseSearch', calls[2].params.command)
      eq(4, calls[2].params.arguments[1].page)
      eq(false, tex.inverse_search_position(0, 25, 80))
      eq(false, tex.inverse_search_position(4, 0 / 0, 80))
      eq(2, #calls)
    end, debug.traceback)
    require('tex-tools.viewer').show_location = show
    if not ok then
      error(err)
    end
  end)

  check('Skim uses the returned PDF coordinates as argv without another SyncTeX query', function()
    local client = fixture()
    config.setup({ lsp = 'latex-lsp', viewer = { method = 'skim' } })
    local jobstart, executable = vim.fn.jobstart, vim.fn.executable
    local argv
    vim.fn.executable = function()
      return 1
    end
    vim.fn.jobstart = function(command)
      argv = command
      return 1
    end
    local ok, err = xpcall(function()
      eq(
        true,
        require('tex-tools.viewer').show_location(client, {
          pdfUri = 'file:///private/tmp/quoted%20%22%24%28.pdf',
          locations = { { page = 7, x = 12.5, y = 81.25 } },
        })
      )
      eq('osascript', argv[1])
      eq('/private/tmp/quoted "$(.pdf', argv[4])
      eq({ '7', '12.5', '81.25' }, vim.list_slice(argv, 5))
      eq(nil, argv[3]:find('synctex', 1, true))
    end, debug.traceback)
    vim.fn.jobstart, vim.fn.executable = jobstart, executable
    if not ok then
      error(err)
    end
  end)

  check('outline consumes symbols and include links in source order', function()
    local client, calls, bufnr = fixture()
    local root = vim.uri_from_bufnr(bufnr)
    local child = 'file:///private/tmp/chapter.tex'
    function client:request_sync(method, params)
      calls[#calls + 1] = { method = method, params = params }
      if method == 'workspace/executeCommand' then
        return { result = { status = 'idle', rootUri = root } }
      end
      if method == 'textDocument/documentSymbol' then
        return {
          result = params.textDocument.uri == root and {
            {
              name = 'Root',
              kind = 3,
              detail = 'section',
              selectionRange = { start = { line = 0, character = 0 } },
            },
            { name = 'label', kind = 20, selectionRange = { start = { line = 0, character = 1 } } },
            {
              name = 'Last',
              kind = 3,
              detail = 'section',
              selectionRange = { start = { line = 1, character = 0 } },
            },
          } or {
            {
              name = 'Child',
              kind = 3,
              detail = 'subsection',
              selectionRange = { start = { line = 0, character = 0 } },
            },
          },
        }
      end
      return {
        result = params.textDocument.uri == root and {
          { target = child, range = { start = { line = 0, character = 4 } } },
        } or {},
      }
    end
    local snapshot = assert(tex.outline_entries({ project = true }))
    eq(
      { 'Root', 'Child', 'Last' },
      vim.tbl_map(function(entry)
        return entry.title
      end, snapshot.entries)
    )
    eq('/private/tmp/chapter.tex', snapshot.entries[2].path)
    eq('utf-16', snapshot.entries[2].encoding)
    eq(
      { 'Child' },
      vim.tbl_map(function(entry)
        return entry.title
      end, tex.outline_entries({ project = true, query = 'child' }).entries)
    )
  end)
end
