return function(h)
  local test, eq, buffer, at, keys = h.test, h.eq, h.buffer, h.at, h.keys
  local tex = require('tex-tools')
  local function titles(snapshot)
    return vim.tbl_map(function(entry)
      return entry.title
    end, snapshot.entries)
  end
  test('outline shows levels, short titles, stars and current section without texlab', function()
    buffer([=[\section*[Short]{Long}
body
\subsection{中文}
child
% \section{comment}
\newcommand{\test}{\section{definition}}
\begin{verbatim}
\section{literal}
\end{verbatim}]=])
    at('child')
    local snapshot = assert(tex.outline_entries())
    eq({ 'Short', '中文' }, titles(snapshot))
    eq(true, snapshot.entries[1].starred)
    eq(4, snapshot.entries[2].level)
    eq(true, snapshot.entries[2].current)
    eq({ '中文' }, titles(assert(tex.outline_entries({ query = '中文' }))))
  end)
  test('outline ignores inline verbatim headings and include commands', function()
    buffer([=[\verb|\section{Fake}| \lstinline{\section{Also fake}}
\mintinline{tex}|\section{Still fake}| \section{Real}]=])
    eq({ 'Real' }, titles(assert(tex.outline_entries())))
  end)
  local function project_test(name, fn)
    test('project outline: ' .. name, function()
      local directory = vim.fn.tempname() .. ' with spaces'
      vim.fn.mkdir(directory .. '/chapters', 'p')
      local clients = vim.lsp.get_clients
      local ok, err = xpcall(function()
        fn(directory)
      end, debug.traceback)
      vim.lsp.get_clients = clients
      vim.fn.delete(directory, 'rf')
      if not ok then
        error(err)
      end
    end)
  end
  project_test('expands includes in source order and uses unsaved child buffers', function(dir)
    vim.fn.writefile({ '\\subsection{Disk}', '\\input{nested}' }, dir .. '/chapters/child.tex')
    vim.fn.writefile({ '\\subsubsection{Nested}' }, dir .. '/chapters/nested.tex')
    local child = buffer('\\subsection{Unsaved}\n\\input{nested}')
    vim.api.nvim_buf_set_name(child, dir .. '/chapters/child.tex')
    local main = buffer(
      '\\documentclass{article}\n\\section{Before}\n\\input{chapters/child}\n\\include{missing}\n\\section{After}'
    )
    vim.api.nvim_buf_set_name(main, dir .. '/main.tex')
    vim.lsp.get_clients = function()
      return {}
    end
    local snapshot = assert(tex.outline_entries({ project = true }))
    eq({ 'Before', 'Unsaved', 'Nested', 'After' }, titles(snapshot))
    eq(1, #snapshot.warnings)
    eq(child, snapshot.entries[2].bufnr)
    eq({ 'Unsaved', 'Nested' }, titles(assert(tex.outline_entries({ project = true, query = 'chapters' }))))
    eq(true, vim.bo[child].modified)
  end)
  project_test('detects cycles, permits repeated includes and follows root directives', function(dir)
    vim.fn.writefile(
      { '\\documentclass{article}', '\\section{Main}', '\\input{child}', '\\input{child}' },
      dir .. '/main.tex'
    )
    local child = buffer('% !TeX root = main.tex\n\\subsection{Child}\n\\input{main}')
    vim.api.nvim_buf_set_name(child, dir .. '/child.tex')
    vim.lsp.get_clients = function()
      return {}
    end
    local snapshot = assert(tex.outline_entries({ project = true }))
    eq({ 'Main', 'Child', 'Child' }, titles(snapshot))
    eq(2, #snapshot.warnings)
  end)
  project_test('respects selected texlab main file', function(dir)
    local main = buffer('\\documentclass{article}\n\\section{Chosen}')
    vim.api.nvim_buf_set_name(main, dir .. '/chosen.tex')
    local child = buffer('child')
    vim.api.nvim_buf_set_name(child, dir .. '/child.tex')
    local client = { config = { root_dir = dir }, settings = {} }
    vim.lsp.get_clients = function()
      return { client }
    end
    eq(true, tex.main_file('chosen.tex'))
    eq({ 'Chosen' }, titles(assert(tex.outline_entries({ project = true }))))
  end)
  test('outline native window supports filtering, refresh, jump and close', function()
    local source = buffer('\\section{First}\nbody\n\\subsection{Second}\nother')
    at('body')
    local origin = vim.api.nvim_get_current_win()
    local ok, panel = tex.outline()
    eq(true, ok)
    eq('tex-tools-outline', vim.bo[panel].filetype)
    eq(false, vim.bo[panel].modifiable)
    eq(true, vim.api.nvim_get_current_line():find('> ', 1, true) ~= nil)
    local input = vim.ui.input
    vim.ui.input = function(_, callback)
      callback('Second')
    end
    keys('f')
    vim.ui.input = input
    eq(true, vim.api.nvim_get_current_line():find('Second', 1, true) ~= nil)
    vim.api.nvim_buf_set_lines(source, 2, 3, false, { '\\subsection{Second edited}' })
    keys('r')
    eq(true, vim.api.nvim_get_current_line():find('Second edited', 1, true) ~= nil)
    keys('<CR>')
    eq(origin, vim.api.nvim_get_current_win())
    eq(source, vim.api.nvim_get_current_buf())
    eq({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    eq(false, vim.api.nvim_buf_is_valid(panel))
    eq(true, tex.outline())
    keys('q')
    eq(origin, vim.api.nvim_get_current_win())
  end)
  project_test('cross-file jumps keep modified source visible with hidden disabled', function(dir)
    vim.fn.writefile({ '\\subsection{Target}' }, dir .. '/child.tex')
    local main = buffer('\\documentclass{article}\n\\section{Main}\n\\input{child}')
    vim.api.nvim_buf_set_name(main, dir .. '/main.tex')
    vim.lsp.get_clients = function()
      return {}
    end
    local hidden = vim.o.hidden
    vim.o.hidden = false
    local origin = vim.api.nvim_get_current_win()
    local ok, err = xpcall(function()
      eq(true, tex.outline({ project = true, query = 'Target' }))
      keys('<CR>')
      eq(dir .. '/child.tex', vim.api.nvim_buf_get_name(0))
      eq(main, vim.api.nvim_win_get_buf(origin))
      eq(true, vim.bo[main].modified)
      vim.api.nvim_win_close(0, true)
    end, debug.traceback)
    vim.o.hidden = hidden
    if not ok then
      error(err)
    end
  end)
  test('outline cancellation and missing matches do not navigate', function()
    buffer('\\section{First}')
    local input = vim.ui.input
    local ok, panel = tex.outline({ query = 'missing' })
    eq(true, ok)
    vim.ui.input = function(_, callback)
      callback(nil)
    end
    keys('f<CR>')
    vim.ui.input = input
    eq(panel, vim.api.nvim_get_current_buf())
    keys('q')
  end)
  test('outline errors are actionable for unknown project roots and missing parsers', function()
    buffer('child')
    eq(nil, tex.outline_entries({ project = true }))
    local parser = vim.treesitter.get_string_parser
    vim.treesitter.get_string_parser = function()
      error('missing parser')
    end
    eq(nil, tex.outline_entries())
    vim.treesitter.get_string_parser = parser
  end)
end
