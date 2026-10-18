return function(h)
  local tex, eq = require('tex-tools'), h.eq
  local directory, client, probes, output, captured
  local function report(aux, out, final, stem)
    return ("Rc files read (in order):\n  ./.latexmkrc\nLatexmk: Cwd: '%s'\nLatexmk: Normalized aux dir, out dir, out2 dir:\n  '%s', '%s', '%s'\nLatexmk: Base name of generated files:\n  '%s'\n"):format(
      directory,
      aux,
      out,
      final,
      stem or 'main'
    )
  end
  local function fixture()
    directory = vim.fn.tempname() .. ' latexmk project'
    vim.fn.mkdir(directory, 'p')
    local source = '\\documentclass{article}\n\\begin{document}text\\end{document}'
    local bufnr = h.buffer(source)
    vim.api.nvim_buf_set_name(bufnr, directory .. '/main.tex')
    vim.fn.writefile(vim.split(source, '\n'), directory .. '/main.tex')
    vim.fn.writefile({ '$out_dir = "build";' }, directory .. '/.latexmkrc')
    vim.bo.modified = false
    client = {
      id = bufnr + 79000,
      name = 'texlab',
      handlers = {},
      config = { root_dir = directory },
      settings = {
        texlab = {
          build = { executable = 'latexmk', args = { '-pdf', '-synctex=1', '%f' } },
          forwardSearch = { executable = vim.v.progpath, args = { '%l', '%p', '%f' } },
        },
      },
    }
    function client:request(_, _, callback)
      callback(nil, { status = 1 })
      return true, 17
    end
    vim.lsp.get_clients = function()
      return { client }
    end
    probes, captured, output = 0, nil, report('build', 'build', 'build')
    local executable = vim.fn.executable
    vim.fn.executable = function(name)
      return name == 'latexmk' and 1 or executable(name)
    end
    vim.system = function(argv, opts)
      probes, captured = probes + 1, { argv = argv, opts = opts }
      return {
        wait = function()
          return { code = 0, stdout = output }
        end,
      }
    end
  end
  local function check(name, fn)
    h.test('latexmk artifacts: ' .. name, function()
      local clients, system, executable, jobs, notify =
        vim.lsp.get_clients, vim.system, vim.fn.executable, vim.fn.jobstart, vim.notify
      local ok, err = xpcall(function()
        fixture()
        fn()
      end, debug.traceback)
      vim.lsp.get_clients, vim.system, vim.fn.executable, vim.fn.jobstart, vim.notify =
        clients, system, executable, jobs, notify
      if directory then
        vim.fn.delete(directory, 'rf')
      end
      tex.setup()
      if not ok then
        error(err)
      end
    end)
  end
  check('computed rc directories and jobname drive all artifact paths', function()
    output = report('aux files', 'intermediate', "final % author's 中文", 'custom job')
    local info = assert(tex.project_info())
    eq(directory .. '/aux files/custom job.log', info.log_file)
    eq(directory .. "/final % author's 中文/custom job.pdf", info.pdf_file)
    eq(directory .. "/final % author's 中文/custom job.synctex.gz", info.synctex_file)
    eq(directory, captured.opts.cwd)
    eq({ 'latexmk', '-dir-report-only', directory .. '/main.tex' }, captured.argv)
  end)
  check('unchanged actions reuse the probe and rc creation/edit/deletion invalidates it', function()
    eq(directory .. '/build/main.pdf', tex.project_info().pdf_file)
    eq(directory .. '/build/main.pdf', tex.project_info().pdf_file)
    eq(1, probes)
    output = report('new output', 'new output', 'new output')
    vim.fn.writefile({ '$out_dir = "new output";' }, directory .. '/.latexmkrc')
    eq(directory .. '/new output/main.pdf', tex.project_info().pdf_file)
    eq(2, probes)
    output = report('.', '.', '.')
    vim.fn.delete(directory .. '/.latexmkrc')
    eq(directory .. '/main.pdf', tex.project_info().pdf_file)
    eq(3, probes)
    vim.fn.writefile({ '$out_dir = "build";' }, directory .. '/.latexmkrc')
    tex.project_info()
    eq(4, probes)
  end)
  check('explicit locator overrides win without modifying texlab settings', function()
    local build = client.settings.texlab.build
    build.auxDirectory, build.logDirectory, build.pdfDirectory = 'explicit aux', 'explicit logs', 'explicit pdf'
    local before = vim.deepcopy(client.settings)
    local info = assert(tex.project_info())
    eq(directory .. '/explicit logs/main.log', info.log_file)
    eq(directory .. '/explicit pdf/main.pdf', info.pdf_file)
    eq(before, client.settings)
  end)
  check('directory and rc arguments are literal, while cleanup and preview are never run', function()
    client.settings.texlab.build.args =
      { '-pdf', '-C', '-pvc', '-r', 'config with spaces.rc', '--outdir=cli output', '%f' }
    output = report('cli output', 'cli output', 'cli output')
    eq(directory .. '/cli output/main.pdf', tex.project_info().pdf_file)
    eq(
      { 'latexmk', '-r', 'config with spaces.rc', '-outdir=cli output', '-dir-report-only', directory .. '/main.tex' },
      captured.argv
    )
    output = report('changed', 'changed', 'changed')
    vim.fn.writefile({ '$out_dir = "changed";' }, directory .. '/config with spaces.rc')
    eq(directory .. '/changed/main.pdf', tex.project_info().pdf_file)
    eq(2, probes)
  end)
  check('unsupported reports retain configured argument fallback', function()
    output = 'latexmk: unknown option -dir-report-only'
    client.settings.texlab.build.args = { '-outdir=argument output', '%f' }
    eq(directory .. '/argument output/main.pdf', tex.project_info().pdf_file)
  end)
  check('both PDF open and forward search use discovered output without a main override', function()
    vim.fn.mkdir(directory .. '/build', 'p')
    vim.fn.writefile({ 'pdf' }, directory .. '/build/main.pdf')
    local calls = {}
    vim.fn.jobstart = function(argv)
      calls[#calls + 1] = argv
      return #calls
    end
    tex.setup({ viewer = { method = 'generic', executable = vim.v.progpath } })
    eq(true, tex.view())
    eq(directory .. '/build/main.pdf', calls[1][2])
    eq(true, tex.forward_search())
    eq({ vim.v.progpath, '1', directory .. '/build/main.pdf', directory .. '/main.tex' }, calls[2])
    eq(1, probes)
  end)
  check('compiler failure stays a failure even when a PDF exists and the message explains it', function()
    vim.fn.mkdir(directory .. '/build', 'p')
    vim.fn.writefile({ 'partial pdf' }, directory .. '/build/main.pdf')
    local message
    vim.notify = function(value)
      message = value
    end
    eq(true, tex.build())
    eq('failed', tex.build_status().phase)
    eq(1, tex.build_status().result)
    assert(message:find('compiler reported errors', 1, true))
    assert(message:find('PDF exists but may be incomplete', 1, true))
    assert(message:find(':TexToolsLog', 1, true))
  end)
end
