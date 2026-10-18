return function(h)
  local tex, manager = require('tex-tools'), require('tex-tools.build')
  local eq = h.eq
  local directory
  local function check(name, fn)
    h.test('project management: ' .. name, function()
      local clients, notify, input = vim.lsp.get_clients, vim.notify, vim.ui.input
      directory = vim.fn.tempname() .. ' project'
      vim.fn.mkdir(directory, 'p')
      local ok, err = xpcall(fn, debug.traceback)
      vim.lsp.get_clients, vim.notify, vim.ui.input = clients, notify, input
      vim.fn.delete(directory, 'rf')
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  local function fixture(name)
    local bufnr = h.buffer('\\documentclass{article}')
    vim.api.nvim_buf_set_name(bufnr, directory .. '/' .. (name or 'main') .. '.tex')
    vim.fn.writefile({ '\\documentclass{article}' }, directory .. '/main.tex')
    vim.fn.writefile({ '\\documentclass{book}' }, directory .. '/book.tex')
    vim.bo.modified = false
    local client = {
      id = bufnr + 50000,
      name = 'texlab',
      config = { root_dir = directory },
      settings = { texlab = { build = { executable = 'tectonic' } } },
      handlers = {},
    }
    local requests = {}
    function client:request(method, params, callback)
      requests[#requests + 1] = { method = method, params = params, callback = callback }
      return true, #requests
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    vim.notify = function() end
    return client, requests, bufnr
  end
  check('query, session override, reset and configuration precedence', function()
    local client = fixture()
    eq({ true, directory .. '/main.tex' }, { tex.main_file() })
    eq({ true, directory .. '/book.tex' }, { tex.main_file('book.tex') })
    eq('session', tex.project_info().main_source)
    tex.setup({ build = { main_file = 'main.tex' } })
    eq(directory .. '/book.tex', tex.project_info().main_file)
    eq({ true, directory .. '/main.tex' }, { tex.main_file(false) })
    eq('configuration', tex.project_info().main_source)
    eq(nil, require('tex-tools.build').state(client).request_id)
  end)
  check('changing main affects build, log and cleanup resolution without editing sources', function()
    local client, calls, bufnr = fixture('child')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'child content' })
    vim.bo.modified = false
    eq(true, tex.main_file('book.tex'))
    eq(true, tex.build())
    eq(vim.uri_from_fname(directory .. '/book.tex'), calls[1].params.textDocument.uri)
    calls[1].callback(nil, { status = 0 })
    vim.fn.writefile({ 'aux' }, directory .. '/book.aux')
    vim.fn.writefile({ 'untouched' }, directory .. '/main.aux')
    eq({ true, 1 }, { tex.clean() })
    eq(1, vim.fn.filereadable(directory .. '/main.aux'))
    eq('child content', h.content())
    eq(directory .. '/book.log', tex.project_info().log_file)
    eq('book', require('tex-tools.project').resolve(client).stem)
  end)
  check('other clients keep their main and delayed selection targets the initiating client', function()
    local first = fixture()
    local second = fixture('other')
    local callback
    vim.lsp.get_clients = function()
      return { first }
    end
    vim.ui.input = function(_, cb)
      callback = cb
    end
    vim.cmd.TexToolsMain('select')
    vim.lsp.get_clients = function()
      return { second }
    end
    callback('book.tex')
    eq(directory .. '/book.tex', require('tex-tools.project').resolve(first).main_file)
    eq(directory .. '/other.tex', tex.project_info().main_file)
  end)
  check('busy clients reject changes and cancelled selection does nothing', function()
    local client = fixture()
    manager.begin(client, 'file:///main.tex')
    eq(false, tex.main_file('book.tex'))
    eq(true, tex.main_file())
    manager.finish(client, manager.state(client).generation, 0)
    manager.state(client).cleaning = true
    eq(false, tex.main_file(false))
    manager.state(client).cleaning = nil
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    vim.cmd.TexToolsMain('select')
    eq(directory .. '/main.tex', tex.project_info().main_file)
  end)
  check('invalid main paths and cycles preserve prior selection', function()
    fixture()
    eq(true, tex.main_file('book.tex'))
    eq(false, tex.main_file('missing.tex'))
    eq(false, tex.main_file('main.pdf'))
    vim.fn.writefile({ '% !TeX root = cycle.tex' }, directory .. '/cycle.tex')
    eq(false, tex.main_file('cycle.tex'))
    eq(directory .. '/book.tex', tex.project_info().main_file)
    vim.cmd.TexToolsMain('reset')
    eq(directory .. '/main.tex', tex.project_info().main_file)
  end)
  check('info exposes independent snapshots and commands display paths', function()
    local client = fixture()
    client.settings.texlab.build.args = { '-X', 'compile', '%f' }
    local info = tex.project_info()
    eq(directory .. '/main.pdf', info.pdf_file)
    eq(directory .. '/main.synctex.gz', info.synctex_file)
    info.build.args[1] = 'modified'
    eq('-X', client.settings.texlab.build.args[1])
    local message
    vim.notify = function(value)
      message = value
    end
    vim.cmd.TexToolsInfo()
    eq(true, message:find('Main: ' .. directory .. '/main.tex', 1, true) ~= nil)
    eq(true, message:find('Compiler: tectonic', 1, true) ~= nil)
  end)
  check('on-save does not silently replace an explicit main with the saved child', function()
    local client, requests = fixture('child')
    eq(true, tex.main_file('book.tex'))
    client.settings.texlab.build.onSave = true
    vim.bo.modified = true
    eq(false, tex.build())
    eq(0, #requests)
    eq(true, vim.bo.modified)
  end)
  check('missing clients return errors without changing editor state', function()
    h.buffer('source')
    vim.lsp.get_clients = function()
      return {}
    end
    eq(false, tex.main_file('book.tex'))
    eq(nil, tex.project_info())
    eq('source', h.content())
  end)
end
