return function(h)
  local child_env = vim.fn.environ()
  child_env.VIMRUNTIME = nil
  local tex, eq = require('tex-tools'), h.eq
  local directory
  local real_jobstart = vim.fn.jobstart
  local function check(name, fn)
    h.test('native viewer: ' .. name, function()
      local clients, notify, jobs = vim.lsp.get_clients, vim.notify, vim.fn.jobstart
      directory = vim.fn.tempname() .. ' viewer'
      vim.fn.mkdir(directory, 'p')
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.notify, vim.fn.jobstart = clients, notify, jobs
      vim.fn.delete(directory, 'rf')
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function fixture()
    local bufnr = h.buffer('\\documentclass{article}\nsource')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/main.tex')
    vim.fn.writefile({ '\\documentclass{article}', 'source' }, directory .. '/main.tex')
    vim.bo.modified = false
    local client = {
      id = bufnr + 60000,
      name = 'texlab',
      config = { root_dir = directory },
      handlers = {},
      settings = { texlab = { build = { executable = 'tectonic' } } },
    }
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    local calls = {}
    vim.fn.jobstart = function(argv, opts)
      calls[#calls + 1] = { argv = argv, opts = opts }
      return 42
    end
    return client, calls
  end
  check('view uses resolved artifact and never requests forward search', function()
    local _, calls = fixture()
    tex.setup({ viewer = { method = 'generic', executable = vim.v.progpath, args = { '--test-option' } } })
    eq(false, tex.view())
    eq(0, #calls)
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(true, tex.view())
    eq({ vim.v.progpath, '--test-option', directory .. '/main.pdf' }, calls[1].argv)
    eq(directory, calls[1].opts.cwd)
    eq(true, calls[1].opts.detach)
    eq(nil, package.loaded['tex-tools.viewer'].last_process)
  end)
  check('Folio consumes server coordinates and honors focus without a second SyncTeX query', function()
    local client, calls = fixture()
    client.name, client.server_capabilities =
      'texquill', { executeCommandProvider = { commands = { 'latex.inverseSearch' } } }
    tex.setup({ lsp = 'texquill', viewer = { method = 'folio', executable = vim.v.progpath, focus = false } })
    local pdf = directory .. '/中文 %.pdf'
    vim.fn.writefile({ 'pdf' }, pdf)
    local result = {
      rootUri = vim.uri_from_bufnr(0),
      pdfUri = vim.uri_from_fname(pdf),
      locations = { { page = 2, x = 130, y = 220, h = 120, v = 224, width = 300, height = 12 } },
    }
    eq(true, require('tex-tools.viewer').show_location(client, result))
    local argv = calls[1].argv
    eq('--inverse-search-position', argv[2])
    assert(argv[3]:find('--position', 1, true) and argv[3]:find('%p', 1, true))
    eq('--no-focus', argv[4])
    eq('--synctex-location', argv[5])
    eq(result.locations[1], vim.json.decode(argv[6]))
    eq({ '--', pdf }, vim.list_slice(argv, 7))
    assert(not vim.tbl_contains(argv, '--forward-search'))
    local inverse = require('tex-tools.inverse')
    local callback = assert(tex.inverse_search_command('folio'))
    local stopped = false
    client.is_stopped = function()
      return stopped
    end
    local record = vim.json.decode(
      table.concat(
        vim.fn.readfile(callback.registry .. '/' .. vim.fn.sha256(callback.server .. ':' .. vim.fn.getpid()) .. '.json'),
        '\n'
      )
    )
    assert(inverse.score_pdf(pdf, record.token))
    eq(nil, inverse.score_pdf(pdf, 'old-token'))
    stopped = true
    eq(nil, inverse.score_pdf(pdf, record.token))
  end)
  check('Folio callback routes PDF points through the owning LSP with an unrelated current buffer', function()
    local client = fixture()
    client.name, client.server_capabilities =
      'texquill', { executeCommandProvider = { commands = { 'latex.inverseSearch' } } }
    tex.setup({ lsp = 'texquill', viewer = { method = 'folio', executable = vim.v.progpath } })
    local pdf = directory .. "/中文 %x ' | %.pdf"
    vim.fn.writefile({ 'pdf' }, pdf)
    local source, bufnr = vim.uri_from_bufnr(0), vim.api.nvim_get_current_buf()
    local result =
      { rootUri = source, pdfUri = vim.uri_from_fname(pdf), locations = { { page = 2, x = 130, y = 220 } } }
    eq(true, require('tex-tools.viewer').show_location(client, result))
    local requests, callbacks = {}, {}
    client.request = function(_, method, params, callback, buffer)
      requests[#requests + 1] = { method = method, params = params, bufnr = buffer }
      callbacks[#callbacks + 1] = callback
      return true, #requests
    end
    local callback = assert(tex.inverse_search_command('folio'))
    local argv = vim.deepcopy(callback.argv)
    argv[1] = vim.fn.exepath('nvim')
    argv[#argv - 3], argv[#argv - 2], argv[#argv - 1], argv[#argv] = '2', '130.5', '220.25', pdf
    h.buffer('unrelated', 'text')
    local completed
    vim.system(argv, { text = true, env = child_env, clear_env = true }, function(value)
      completed = value
    end)
    assert(
      vim.wait(10000, function()
        return completed ~= nil
      end, 10),
      'Folio RPC helper timed out'
    )
    eq(0, completed.code)
    eq(1, #requests)
    eq({ uri = source, page = 2, x = 130.5, y = 220.25 }, requests[1].params.arguments[1])
    eq(bufnr, requests[1].bufnr)
    local location =
      { uri = source, range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 0 } } }
    callbacks[1](nil, { rootUri = source, pdfUri = result.pdfUri, locations = { location } })
    eq(source, vim.uri_from_bufnr(0))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    eq(true, require('tex-tools.inverse_rpc').dispatch_position(callback.registry, pdf, 2, 1, 2))
    eq(true, require('tex-tools.inverse_rpc').dispatch_position(callback.registry, pdf, 2, 3, 4))
    h.buffer('still unrelated', 'text')
    callbacks[2](nil, { rootUri = source, pdfUri = result.pdfUri, locations = { location } })
    eq('still unrelated', vim.api.nvim_get_current_line())
    callbacks[3](
      nil,
      { rootUri = source, pdfUri = vim.uri_from_fname(directory .. '/other.pdf'), locations = { location } }
    )
    eq('still unrelated', vim.api.nvim_get_current_line())
    eq(false, require('tex-tools.inverse_rpc').dispatch_position(callback.registry, pdf, 0, 1, 2))
    eq(
      false,
      require('tex-tools.inverse_rpc').dispatch_position(callback.registry, directory .. '/unknown.pdf', 1, 1, 2)
    )
  end)
  check('Zathura receives a stable inverse callback without forward flags', function()
    local _, calls = fixture()
    tex.setup({ viewer = { method = 'zathura', executable = vim.v.progpath } })
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(true, tex.view())
    eq('--synctex-editor-command', calls[1].argv[2])
    assert(calls[1].argv[3]:find('--registry', 1, true))
    assert(not calls[1].argv[3]:find(vim.v.servername, 1, true))
    assert(calls[1].argv[3]:find('%{input}', 1, true))
    eq(directory .. '/main.pdf', calls[1].argv[4])
  end)
  check('Skim opens PDF independently of source position', function()
    local _, calls = fixture()
    tex.setup({ viewer = { method = 'skim', executable = vim.v.progpath } })
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(true, tex.view())
    eq({ vim.v.progpath, '-a', 'Skim', directory .. '/main.pdf' }, calls[1].argv)
  end)
  check('Skim background viewing is opt-in', function()
    local _, calls = fixture()
    tex.setup({ viewer = { method = 'skim', executable = vim.v.progpath, focus = false } })
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(true, tex.view())
    eq({ vim.v.progpath, '-g', '-a', 'Skim', directory .. '/main.pdf' }, calls[1].argv)
  end)
  check('auto detection reuses texlab viewer knowledge', function()
    local client = fixture()
    client.settings.texlab.forwardSearch = { executable = '/Applications/Skim.app/Contents/SharedSupport/displayline' }
    eq('skim', require('tex-tools.viewer').detect(client).method)
    client.settings.texlab.forwardSearch.executable = '/custom/zathura'
    eq('zathura', require('tex-tools.viewer').detect(client).method)
    eq('/custom/zathura', require('tex-tools.viewer').detect(client).executable)
  end)
  check('selected main drives forward-search PDF while retaining child position', function()
    local client, calls = fixture()
    local main = directory .. '/book %.tex'
    vim.fn.writefile({ '\\documentclass{book}' }, main)
    eq(true, tex.main_file(main))
    client.settings.texlab.forwardSearch = { executable = vim.v.progpath, args = { '%l', '%p', '%f', '--literal' } }
    eq(false, tex.forward_search())
    eq(0, #calls)
    vim.fn.writefile({ 'pdf' }, directory .. '/book %.pdf')
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    eq(true, tex.forward_search())
    eq({ vim.v.progpath, '2', directory .. '/book %.pdf', directory .. '/main.tex', '--literal' }, calls[1].argv)
  end)
  check('viewer process receives literal arguments without a shell', function()
    fixture()
    vim.fn.jobstart = real_jobstart
    local script, capture = directory .. '/viewer executable', directory .. '/capture'
    vim.fn.writefile({ '#!/bin/sh', 'capture="$1"', 'shift', [[printf '%s\n' "$@" > "$capture"]] }, script)
    vim.fn.setfperm(script, 'rwx------')
    local literal = "quoted ' | $(false) % argument"
    tex.setup({ viewer = { method = 'generic', executable = script, args = { capture, literal } } })
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(true, tex.view())
    assert(vim.wait(3000, function()
      return vim.fn.filereadable(capture) == 1
    end, 10))
    eq({ literal, directory .. '/main.pdf' }, vim.fn.readfile(capture))
  end)
  check('missing executable and unavailable selected forward configuration fail clearly', function()
    local client, calls = fixture()
    tex.setup({ viewer = { method = 'generic', executable = directory .. '/missing' } })
    vim.fn.writefile({ 'pdf' }, directory .. '/main.pdf')
    eq(false, tex.view())
    eq(0, #calls)
    eq(true, tex.main_file('main.tex'))
    local ok, err = tex.forward_search()
    eq(false, ok)
    assert(err:find('Configure texlab.forwardSearch', 1, true))
    client.settings.texlab.forwardSearch = { executable = directory .. '/missing', args = { '%p' } }
    eq(false, tex.forward_search())
    eq(0, #calls)
  end)
  check('invalid viewer configuration and callbacks are rejected', function()
    fixture()
    for _, opts in ipairs({
      { method = 'unknown' },
      { args = 'bad' },
      { args = { false } },
      { executable = '' },
      { focus = 'false' },
    }) do
      eq(false, pcall(tex.setup, { viewer = opts }))
    end
    eq(nil, tex.inverse_search_command('unknown'))
  end)
  check('inverse search treats filenames as data and preserves modified buffer', function()
    fixture()
    local file = directory .. "/中文 ' | let g:injected = 1 | %.tex"
    vim.fn.writefile({ 'first', '中文 last' }, file)
    local original = vim.api.nvim_get_current_buf()
    vim.bo.modified = true
    local hidden = vim.o.hidden
    vim.o.hidden = false
    local ok, err = tex.inverse_search(file, 999, 3)
    vim.o.hidden = hidden
    eq(true, ok)
    eq(nil, err)
    eq(file, vim.api.nvim_buf_get_name(0))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    eq(true, vim.bo[original].modified)
    eq(nil, vim.g.injected)
    vim.cmd.close()
  end)
  check('inverse search validates inputs and never edits missing files', function()
    fixture()
    local file = directory .. '/main.tex'
    for _, args in ipairs({
      { file, 0 },
      { file, -1 },
      { file, 1.5 },
      { file, 'bad' },
      { file, math.huge },
      { file, 1, 0 },
      { directory, 1 },
      { directory .. '/missing', 1 },
    }) do
      eq(false, tex.inverse_search(unpack(args)))
    end
    eq(directory .. '/main.tex', vim.api.nvim_buf_get_name(0))
  end)
  check('callback helper performs a real RPC jump with quoted and UTF-8 paths', function()
    fixture()
    local file = directory .. "/中文 ' quote | %.tex"
    vim.fn.writefile({ 'first', 'second' }, file)
    local callback = assert(tex.inverse_search_command('zathura'))
    eq('%{line}', callback.argv[#callback.argv - 1])
    eq('%{input}', callback.argv[#callback.argv])
    local argv = vim.deepcopy(callback.argv)
    argv[1] = vim.fn.exepath('nvim') -- portable test launcher for the extracted 0.11 binary
    argv[#argv - 1], argv[#argv] = '2', file
    local result
    vim.system(argv, { text = true, env = child_env, clear_env = true }, function(value)
      result = value
    end)
    assert(
      vim.wait(10000, function()
        return result ~= nil
      end, 10),
      'RPC helper timed out'
    )
    eq(0, result.code)
    eq(file, vim.api.nvim_buf_get_name(0))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    local skim = assert(tex.inverse_search_command('skim'))
    eq('%line', skim.argv[#skim.argv - 1])
    eq('%file', skim.argv[#skim.argv])
    eq(callback.server, skim.server)
    -- Skim escapes these four characters before substituting into double
    -- quotes; exercise that documented shell-command path as well as RPC.
    local special = directory .. '/中文 \' " $() ` quote | %.tex'
    vim.fn.writefile({ 'one', 'two' }, special)
    local command = vim.fn.shellescape(vim.fn.exepath('nvim')) .. ' ' .. skim.arguments
    command = command:gsub('%%line', '2'):gsub('%%file', function()
      return special:gsub('[$"`\\]', '\\%0')
    end)
    result = nil
    vim.system({ 'sh', '-c', command }, { text = true, env = child_env, clear_env = true }, function(value)
      result = value
    end)
    assert(
      vim.wait(10000, function()
        return result ~= nil
      end, 10),
      'Skim callback timed out'
    )
    eq(0, result.code)
    eq(special, vim.api.nvim_buf_get_name(0))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
  end)
end
