-- Optional real texlab/latexmk regression. Only temporary files are changed.
-- TEX_TOOLS_LIVE_PROJECT=/path/to/project nvim --clean --headless -i NONE -l tests/live_latexmk.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(root)
vim.o.swapfile, vim.o.shadafile = false, 'NONE'
local directory = vim.fn.tempname() .. ' live latexmk'
vim.fn.mkdir(directory, 'p')
local client
local function check()
  local file = 'main.tex'
  local original = vim.env.TEX_TOOLS_LIVE_PROJECT
  local source = { '\\documentclass{article}', '\\begin{document}', '\\undefinedtestcommand text', '\\end{document}' }
  local rc = { '$out_dir = "build";' }
  if original then
    file = 'test.tex'
    source = vim.fn.readfile(original .. '/' .. file)
    rc = vim.fn.readfile(original .. '/.latexmkrc')
  end
  local path = directory .. '/' .. file
  local stem = file:sub(1, -5)
  vim.fn.writefile(source, path)
  vim.fn.writefile(rc, directory .. '/.latexmkrc')
  vim.fn.writefile({}, directory .. '/.texlabroot')
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.bo.filetype = 'tex'
  local tex = require('tex-tools')
  tex.setup({ mappings = false })
  local analyzed = false
  local id = assert(vim.lsp.start({
    name = 'texlab',
    cmd = { 'texlab' },
    root_dir = directory,
    settings = {
      texlab = {
        build = {
          executable = 'latexmk',
          args = { '-pdf', '-interaction=nonstopmode', '-synctex=1', '%f' },
          onSave = false,
        },
        diagnosticsDelay = 50,
      },
    },
    handlers = {
      ['textDocument/publishDiagnostics'] = function(err, result, ctx, config)
        vim.lsp.handlers['textDocument/publishDiagnostics'](err, result, ctx, config)
        if not err and result.uri == vim.uri_from_fname(path) then
          analyzed = true
        end
      end,
    },
  }))
  client = assert(vim.lsp.get_client_by_id(id))
  assert(vim.wait(10000, function()
    return client.initialized and analyzed
  end, 10))
  local messages = {}
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  local function build(expected)
    assert(tex.build())
    assert(
      vim.wait(30000, function()
        local phase = tex.build_status().phase
        return phase == expected or phase == 'failed_to_start'
      end, 20),
      vim.inspect(tex.build_status())
    )
    assert(tex.build_status().phase == expected, vim.inspect(tex.build_status()))
  end
  assert(
    vim.wait(10000, function()
      return client.settings.texlab.build.logDirectory == directory .. '/build'
    end, 10),
    'Discovered log directory was not synchronized'
  )
  build('failed')
  local function errors()
    return vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
  end
  assert(
    vim.wait(10000, function()
      for _, diagnostic in ipairs(errors()) do
        if diagnostic.message:find('Undefined control sequence', 1, true) then
          return true
        end
      end
      return false
    end, 10),
    'Undefined commands did not reach native diagnostics'
  )
  local diagnostic_count = #errors()
  assert(diagnostic_count > 0)
  assert(vim.fn.filereadable(directory .. '/build/' .. stem .. '.pdf') == 1)
  assert(table.concat(messages, '\n'):find('PDF exists but may be incomplete', 1, true))
  assert(tex.project_info().log_file == directory .. '/build/' .. stem .. '.log')

  -- Real child processes capture viewer arguments without opening a GUI.
  local script = directory .. '/viewer.lua'
  vim.fn.writefile({
    'vim.fn.writefile({vim.json.encode(vim.list_slice(arg, 2))}, arg[1])',
    "vim.cmd('qa!')",
  }, script)
  local function viewers(expected_pdf)
    local opened, forwarded = directory .. '/opened.json', directory .. '/forwarded.json'
    vim.fn.delete(opened)
    vim.fn.delete(forwarded)
    local common = { '--headless', '--clean', '-i', 'NONE', '-l', script }
    local args = vim.deepcopy(common)
    args[#args + 1] = opened
    tex.setup({ mappings = false, viewer = { method = 'generic', executable = vim.v.progpath, args = args } })
    args = vim.deepcopy(common)
    vim.list_extend(args, { forwarded, '%l', '%p', '%f' })
    client.settings.texlab.forwardSearch = { executable = vim.v.progpath, args = args }
    assert(tex.view())
    assert(tex.forward_search())
    assert(vim.wait(10000, function()
      return vim.fn.filereadable(opened) == 1 and vim.fn.filereadable(forwarded) == 1
    end, 10))
    local function read(file)
      return vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
    end
    assert(read(opened)[1] == expected_pdf, vim.inspect(read(opened)))
    local forward = read(forwarded)
    assert(forward[2] == expected_pdf and forward[3] == path, vim.inspect(forward))
  end
  viewers(directory .. '/build/' .. stem .. '.pdf')

  -- A computed Perl output directory changes between builds, with no LSP overrides.
  vim.fn.writefile({ 'my $prefix = "artifacts";', '$out_dir = "$prefix/pdf files";' }, directory .. '/.latexmkrc')
  source = { '\\documentclass{article}', '\\begin{document}', 'A valid document.', '\\end{document}' }
  vim.api.nvim_buf_set_lines(0, 0, -1, false, source)
  vim.cmd.write()
  build('succeeded')
  local info = assert(tex.project_info())
  assert(info.pdf_file == directory .. '/artifacts/pdf files/' .. stem .. '.pdf', vim.inspect(info))
  assert(vim.fn.filereadable(info.pdf_file) == 1 and vim.fn.filereadable(info.synctex_file) == 1)
  assert(info.log_file == directory .. '/artifacts/pdf files/' .. stem .. '.log')
  assert(
    vim.wait(10000, function()
      return client.settings.texlab.build.logDirectory == directory .. '/artifacts/pdf files' and #errors() == 0
    end, 10),
    'Fixed errors were not cleared after the output directory changed: ' .. vim.inspect(errors())
  )
  viewers(info.pdf_file)
  print(
    ('PASS live latexmk: %d compiler diagnostics, fixed errors cleared, changed rc logs synchronized, PDF-open/forward argv correct'):format(
      diagnostic_count
    )
  )
end
local ok, err = xpcall(check, debug.traceback)
if client then
  client:stop(true)
  vim.wait(2000, function()
    return client:is_stopped()
  end, 10)
end
if ok then
  vim.fn.delete(directory, 'rf')
else
  io.stderr:write(err .. '\nArtifacts: ' .. directory .. '\n')
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
