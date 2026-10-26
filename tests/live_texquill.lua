-- Optional real texquill/latexmk/SyncTeX regression; only temporary files change.
-- TEX_TOOLS_TEXQUILL=/path/to/texquill nvim --clean --headless -i NONE -l tests/live_texquill.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(root)
vim.o.swapfile, vim.o.shadafile, vim.o.hidden = false, 'NONE', true
local directory = vim.fn.tempname() .. ' texquill integration'
vim.fn.mkdir(directory .. '/chapters', 'p')
local client
local function check()
  local main, child = directory .. '/main.tex', directory .. '/chapters/intro.tex'
  vim.fn.writefile({
    '\\documentclass{article}',
    '\\begin{document}',
    '\\section{Root}',
    '\\input{chapters/intro}',
    '\\section{Last}',
    'Last page.',
    '\\end{document}',
  }, main)
  vim.fn.writefile({ '% !TeX root = ../main.tex', '\\subsection{Child}', 'Text for SyncTeX.' }, child)
  vim.fn.writefile({ '$out_dir = "generated";' }, directory .. '/.latexmkrc')
  vim.cmd.edit(vim.fn.fnameescape(child))
  vim.bo.filetype = 'tex'
  local tex = require('tex-tools')
  tex.setup({ lsp = 'texquill', mappings = false })
  local events = {}
  local id = assert(vim.lsp.start({
    name = 'texquill',
    cmd = { vim.env.TEX_TOOLS_TEXQUILL or 'texquill', '--stdio' },
    root_dir = directory,
    capabilities = { workspace = { didChangeWatchedFiles = { dynamicRegistration = false } } },
    init_options = { build = { onSave = false, jobName = 'custom job' } },
    handlers = {
      ['latex/buildFinished'] = function(_, result)
        events[#events + 1] = result
      end,
    },
  }))
  client = assert(vim.lsp.get_client_by_id(id))
  assert(
    vim.wait(10000, function()
      return client.initialized
    end, 10),
    'Server did not initialize'
  )
  require('tex-tools.lsp').attach(client)
  -- Fail immediately if the texquill path falls back to local latexmk probing.
  local latexmk = require('tex-tools.latexmk')
  latexmk.resolve = function()
    error('texquill must own artifact discovery')
  end
  local info = assert(tex.project_info())
  assert(info.main_file == main, vim.inspect(info))
  assert(info.pdf_file == nil, 'Idle server should not invent artifact paths')
  assert(tex.build())
  assert(
    vim.wait(30000, function()
      return #events == 1
    end, 20),
    'Build did not finish'
  )
  assert(events[1].status == 'success', vim.inspect(events[1]))
  local status = assert(tex.build_status())
  assert(status.phase == 'success', vim.inspect(status))
  info = assert(tex.project_info())
  assert(info.pdf_file == directory .. '/generated/custom job.pdf', vim.inspect(info))
  assert(info.log_file == directory .. '/generated/custom job.log', vim.inspect(info))
  assert(vim.fn.filereadable(info.pdf_file) == 1)
  assert(client.settings.texlab == nil, 'texlab settings leaked into texquill')
  local snapshot = assert(tex.outline_entries({ project = true }))
  local titles = vim.tbl_map(function(entry)
    return entry.title
  end, snapshot.entries)
  assert(vim.deep_equal(titles, { 'Root', 'Child', 'Last' }), vim.inspect(snapshot))
  local opened, panel = tex.outline({ project = true })
  assert(opened and vim.bo[panel].filetype == 'tex-tools-outline')
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'xt', false)
  assert(vim.api.nvim_buf_get_name(0) == child, 'Outline did not jump to child')
  -- Validate the real server query; intercept only viewer launch.
  vim.api.nvim_win_set_cursor(0, { 3, 1 })
  local viewer, location = require('tex-tools.viewer'), nil
  viewer.show_location = function(_, result)
    location = result
    return true
  end
  assert(tex.forward_search())
  assert(
    vim.wait(10000, function()
      return location ~= nil
    end, 10),
    'No forward-search result'
  )
  assert(location.pdfUri == vim.uri_from_fname(info.pdf_file), vim.inspect(location))
  assert(location.locations[1].page >= 1)
  local point = location.locations[1]
  local response = assert(client:request_sync('workspace/executeCommand', {
    command = 'latex.inverseSearch',
    arguments = { { uri = vim.uri_from_fname(child), page = point.page, x = point.x, y = point.y } },
  }, 10000))
  assert(not response.err, vim.inspect(response))
  assert(#response.result.locations > 0, vim.inspect(response))
  assert(tex.build_on_save(true))
  assert(client.settings.build.jobName == 'custom job', 'Configuration lost init options')
  assert(tex.build_on_save(false))
  -- Build saves the modified buffer, and diagnostics remain server-owned.
  vim.api.nvim_buf_set_lines(0, 2, 3, false, { '\\undefinedintegrationcommand' })
  assert(tex.build())
  assert(not vim.bo.modified, 'Build did not save the current buffer')
  assert(
    vim.wait(30000, function()
      return #events == 2
    end, 20),
    'Failed build did not finish'
  )
  assert(tex.build_status().phase == 'error', vim.inspect(events[2]))
  local report = assert(client:request_sync('textDocument/diagnostic', {
    textDocument = { uri = vim.uri_from_fname(child) },
  }, 10000))
  assert(not report.err, vim.inspect(report))
  local found = false
  for _, diagnostic in ipairs(report.result.items) do
    found = found or diagnostic.message:find('Undefined control sequence', 1, true) ~= nil
  end
  assert(found, 'Compiler error missing from native LSP diagnostics: ' .. vim.inspect(report))
  vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'Text for SyncTeX.' })
  assert(tex.build())
  assert(
    vim.wait(30000, function()
      return #events == 3
    end, 20),
    'Recovery build did not finish'
  )
  assert(tex.build_status().phase == 'success', vim.inspect(events[3]))
  local pdf = info.pdf_file
  local cleaned, messages = 0, {}
  vim.notify = function(message)
    messages[#messages + 1] = message
    if message == 'Build artifacts cleaned' then
      cleaned = cleaned + 1
    end
  end
  local function clean(full)
    local previous = cleaned
    assert(tex.clean(full))
    assert(
      vim.wait(10000, function()
        return cleaned == previous + 1
      end, 10),
      vim.inspect(messages)
    )
  end
  clean(false)
  assert(vim.fn.filereadable(pdf) == 1, 'Auxiliary cleanup removed PDF')
  clean(true)
  assert(vim.fn.filereadable(pdf) == 0, 'Full cleanup left PDF')
  assert(vim.fn.filereadable(main) == 1 and vim.fn.filereadable(child) == 1)
  print(
    'PASS real texquill: roots, build/status, rc paths, outline panel/jump, SyncTeX, diagnostics, recovery, settings and cleanup'
  )
end
local ok, err = xpcall(check, debug.traceback)
if client then
  client:stop()
  vim.wait(5000, function()
    return client:is_stopped()
  end, 10)
end
vim.cmd('silent! %bwipeout!')
vim.fn.delete(directory, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
