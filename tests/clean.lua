return function(h)
  local tex, manager = require('tex-tools'), require('tex-tools.build')
  local eq = h.eq
  local directory
  local function check(name, fn)
    h.test('build cleanup: ' .. name, function()
      local get_clients, notify, unlink = vim.lsp.get_clients, vim.notify, vim.uv.fs_unlink
      directory = vim.fn.tempname() .. ' project'
      vim.fn.mkdir(directory, 'p')
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.notify, vim.uv.fs_unlink = get_clients, notify, unlink
      vim.fn.delete(directory, 'rf')
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function write(path)
    vim.fn.writefile({ 'retained content' }, directory .. '/' .. path)
  end
  local function exists(path)
    return vim.uv.fs_lstat(directory .. '/' .. path) ~= nil
  end
  local function fixture(backend)
    local bufnr = h.buffer('\\documentclass{article}')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/main.tex')
    write('main.tex')
    local calls = {}
    local client = {
      id = bufnr + 30000,
      name = 'texlab',
      config = { root_dir = directory },
      settings = { texlab = { build = { executable = backend or 'tectonic', args = { '-X', 'compile', '%f' } } } },
      handlers = {},
      server_capabilities = {
        executeCommandProvider = { commands = { 'texlab.cleanAuxiliary', 'texlab.cleanArtifacts' } },
      },
    }
    function client:request(method, params, callback)
      calls[#calls + 1] = { method = method, params = params, callback = callback }
      return true, #calls
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    return client, calls, bufnr
  end

  check('Tectonic auxiliary cleanup preserves PDF, sources, bibliography and unrelated artifacts', function()
    fixture()
    for _, path in ipairs({ 'main.aux', 'main.log', 'main.synctex.gz', 'main.pdf', 'main.bbl', 'refs.bib', 'other.aux' }) do
      write(path)
    end
    eq({ true, 3 }, { tex.clean() })
    for _, path in ipairs({ 'main.aux', 'main.log', 'main.synctex.gz' }) do
      eq(false, exists(path))
    end
    for _, path in ipairs({ 'main.tex', 'main.pdf', 'main.bbl', 'refs.bib', 'other.aux' }) do
      eq(true, exists(path))
    end
    eq({ true, 1 }, { tex.clean(true) })
    eq(false, exists('main.pdf'))
    eq({ true, 0 }, { tex.clean(true) })
  end)

  check('configured output, auxiliary and log directories are used exactly', function()
    local client = fixture()
    for _, name in ipairs({ 'output', 'aux', 'logs' }) do
      vim.fn.mkdir(directory .. '/' .. name)
    end
    client.settings.texlab.build = {
      executable = '/opt/bin/tectonic',
      args = { '-X', 'compile', '%f', '--outdir=output' },
      auxDirectory = 'aux',
      logDirectory = 'logs',
      filename = 'result.pdf',
    }
    for _, path in ipairs({ 'aux/main.aux', 'logs/main.log', 'output/result.pdf', 'main.aux', 'output/other.pdf' }) do
      write(path)
    end
    eq({ true, 3 }, { tex.clean(true) })
    eq(true, exists('main.aux'))
    eq(true, exists('output/other.pdf'))
    eq(false, exists('output/result.pdf'))
  end)

  check('short output-directory flag is resolved relative to compilation cwd', function()
    local client = fixture()
    vim.fn.mkdir(directory .. '/out')
    client.settings.texlab.build.args = { '-X', 'compile', '%f', '-o', 'out' }
    write('out/main.aux')
    write('out/main.log')
    write('out/main.pdf')
    eq({ true, 3 }, { tex.clean(true) })
  end)

  check('root directives find main and Tectonic defaults to its input directory', function()
    local _, _, bufnr = fixture()
    vim.fn.mkdir(directory .. '/src')
    vim.fn.mkdir(directory .. '/src/chapters')
    write('.texlabroot')
    write('src/main.tex')
    write('src/main.aux')
    write('main.aux')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/src/chapters/child.tex')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '% !TeX root = ../main.tex' })
    eq({ true, 1 }, { tex.clean() })
    eq(false, exists('src/main.aux'))
    eq(true, exists('main.aux'))
  end)

  check('explicit main-file configuration resolves ambiguous children', function()
    fixture()
    write('document.tex')
    write('document.aux')
    tex.setup({ build = { main_file = 'document.tex' } })
    eq({ true, 1 }, { tex.clean() })
    eq(false, exists('document.aux'))
    eq(true, exists('document.tex'))
  end)

  check('latexmk delegates main URI, guards concurrent operations and reports errors', function()
    local client, calls, bufnr = fixture('latexmk')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/child.tex')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '% !TeX root = main.tex' })
    eq(true, tex.clean())
    eq('workspace/executeCommand', calls[1].method)
    eq('texlab.cleanAuxiliary', calls[1].params.command)
    eq({ { uri = vim.uri_from_fname(directory .. '/main.tex') } }, calls[1].params.arguments)
    eq(false, tex.clean(true))
    eq(false, tex.build())
    calls[1].callback(nil)
    eq(nil, manager.state(client).cleaning)
    eq(true, tex.clean(true))
    eq('texlab.cleanArtifacts', calls[2].params.command)
    local message
    vim.notify = function(value)
      message = value
    end
    calls[2].callback({ message = 'latexmk failed' })
    eq('latexmk failed', message)
    eq(nil, manager.state(client).cleaning)
  end)

  check('capability and transport rejections release the cleanup guard', function()
    local client = fixture('latexmk')
    client.server_capabilities.executeCommandProvider.commands = {}
    eq(false, tex.clean())
    eq(nil, manager.state(client).cleaning)
    client.server_capabilities = {}
    function client:request()
      return false
    end
    eq(false, tex.clean())
    eq(nil, manager.state(client).cleaning)
  end)

  check('active builds, ambiguous mains, unsupported backends and project builds refuse cleanup', function()
    local client, _, bufnr = fixture()
    write('main.aux')
    manager.begin(client, vim.uri_from_bufnr(bufnr))
    eq(false, tex.clean())
    manager.finish(client, manager.state(client).generation, 0)
    client.settings.texlab.build.executable = 'custom-compiler'
    eq(false, tex.clean())
    client.settings.texlab.build.executable = 'tectonic'
    client.settings.texlab.build.args = { '-X', 'build' }
    eq(false, tex.clean())
    client.settings.texlab.build.args = { '-X', 'compile', '%f' }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'child with no known parent' })
    eq(false, tex.clean())
    eq(true, exists('main.aux'))
  end)

  check('leaf symlinks are removed without touching targets and directories are refused', function()
    fixture()
    write('target.txt')
    assert(vim.uv.fs_symlink(directory .. '/target.txt', directory .. '/main.aux'))
    eq({ true, 1 }, { tex.clean() })
    eq(true, exists('target.txt'))
    eq(false, exists('main.aux'))
    write('main.aux')
    vim.fn.mkdir(directory .. '/main.log')
    eq(false, tex.clean())
    eq(true, exists('main.aux'))
    eq(true, exists('main.log'))
  end)

  check('partial filesystem failures report the failed path and removed count', function()
    fixture()
    write('main.aux')
    write('main.log')
    local unlink = vim.uv.fs_unlink
    vim.uv.fs_unlink = function(path)
      if path:match('%.log$') then
        return nil, 'EACCES: permission denied', 'EACCES'
      end
      return unlink(path)
    end
    local ok, err = tex.clean()
    eq(false, ok)
    eq(true, err:find('Removed 1 artifacts', 1, true) ~= nil)
    eq(true, err:find('main.log', 1, true) ~= nil)
    eq(true, exists('main.log'))
  end)

  check('unsafe full-clean filename is rejected before deleting auxiliaries', function()
    local client = fixture()
    write('main.aux')
    client.settings.texlab.build.filename = 'main.tex'
    eq(false, tex.clean(true))
    eq(true, exists('main.tex'))
    eq(true, exists('main.aux'))
  end)

  check('real LSP cleanup opens a resolved main document before executing the command', function()
    local bufnr = h.buffer('% !TeX root = main.tex')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/child.tex')
    vim.bo.modified = false
    vim.fn.writefile({ '\\documentclass{article}' }, directory .. '/main.tex')
    tex.setup()
    local messages = {}
    vim.notify = function(message, level)
      messages[#messages + 1] = { message, level }
    end
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
    })
    local client = assert(vim.lsp.get_client_by_id(id))
    local ok, err = xpcall(function()
      eq(
        true,
        vim.wait(3000, function()
          return client.initialized and vim.lsp.buf_is_attached(bufnr, id)
        end)
      )
      eq(true, tex.clean())
      eq(
        true,
        vim.wait(3000, function()
          return manager.state(client).cleaning == nil
        end)
      )
      eq({ 'Build artifacts cleaned', vim.log.levels.INFO }, messages[#messages])
      eq(true, vim.lsp.buf_is_attached(vim.fn.bufnr(directory .. '/main.tex'), id))
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
