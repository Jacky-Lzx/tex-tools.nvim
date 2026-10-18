local M = {}

function M.backend(build)
  return vim.fs.basename(build.executable or 'latexmk'):lower():gsub('%.exe$', '')
end

local function absolute(path, directory)
  path = vim.fs.normalize(path, { expand_env = false })
  if not path:match('^/') and not path:match('^%a:/') then
    path = vim.fs.joinpath(directory, path)
  end
  return vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
end

function M.argument(args, names)
  local result
  for index, argument in ipairs(args or {}) do
    for _, name in ipairs(names) do
      if argument == name then
        result = args[index + 1]
      elseif argument:sub(1, #name + 1) == name .. '=' then
        result = argument:sub(#name + 2)
      end
    end
  end
  return result
end

local function source_lines(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == path then
      return vim.api.nvim_buf_get_lines(bufnr, 0, math.min(200, vim.api.nvim_buf_line_count(bufnr)), false)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, path, '', 200)
  return ok and lines or nil
end

function M.resolve(client, opts)
  opts = opts or {}
  local file = vim.api.nvim_buf_get_name(opts.bufnr or 0)
  if file == '' or file:match('^%w+://') then
    return nil, 'Open a local .tex file first'
  end
  local configured = opts.main_file or require('tex-tools.config').options.build.main_file
  local explicit = configured and true or false
  local base = (client.config or {}).root_dir or vim.fs.dirname(file)
  if configured then
    file = absolute(configured, base)
  end
  local visited, is_main, resolved = {}, explicit, false
  for _ = 1, 16 do
    file = vim.fs.normalize(file, { expand_env = false })
    if visited[file] then
      return nil, 'Cyclic % !TeX root directives'
    end
    visited[file] = true
    local lines = source_lines(file)
    if not lines then
      return nil, 'Could not read main file: ' .. file
    end
    local root
    for _, line in ipairs(lines) do
      root = root or line:match('^%s*%%%s*!%s*[Tt][Ee][Xx]%s+[Rr][Oo][Oo][Tt]%s*=%s*(.-)%s*$')
      if not line:match('^%s*%%') and line:match('\\documentclass[%s%[{]') then
        is_main = true
      end
    end
    if not root then
      resolved = true
      break
    end
    file, is_main = absolute(root, vim.fs.dirname(file)), true
  end
  if not resolved then
    return nil, 'Too many nested % !TeX root directives'
  end
  if not is_main then
    return nil, 'Main file is ambiguous; set % !TeX root or build.main_file'
  end
  if not file:match('%.tex$') then
    return nil, 'The main file must have a .tex extension'
  end
  local directory = vim.fs.dirname(file)
  local markers = vim.fs.find(
    { '.texlabroot', 'texlabroot', 'Tectonic.toml', '.latexmkrc', 'latexmkrc' },
    { path = directory, upward = true, type = 'file', limit = 1, stop = vim.uv.os_homedir() }
  )
  local cwd = markers[1] and vim.fs.dirname(markers[1]) or directory
  local settings = (client.settings or {}).texlab or {}
  local build = settings.build or {}
  local stem = vim.fs.basename(file):sub(1, -5)
  local jobname = M.argument(build.args, { '-jobname', '--jobname' })
  if jobname then
    if jobname == '' or jobname:find('[/\\]') or jobname == '.' or jobname == '..' then
      return nil, 'Compiler jobname must be a basename without directory components'
    end
    stem = jobname
  end
  local filename = build.filename
  if filename == vim.NIL then
    filename = nil
  end
  if filename and filename ~= vim.NIL then
    if
      type(filename) ~= 'string'
      or filename:find('[/\\]')
      or filename == ''
      or filename == '.'
      or filename == '..'
    then
      return nil, 'texlab.build.filename must be a basename without directory components'
    end
  end
  local function dir(value)
    if type(value) == 'string' and value ~= '' then
      return absolute(value, cwd)
    end
    -- Tectonic's compile command defaults to the input file's directory,
    -- even when texlab starts it from a parent containing a root marker.
    return M.backend(build) == 'tectonic' and directory or cwd
  end
  local outdir = M.argument(build.args, { '--outdir', '-outdir', '-output-directory', '--output-directory', '-o' })
  local auxdir = M.argument(build.args, { '-auxdir', '-aux-directory' })
  return {
    main_file = file,
    cwd = cwd,
    stem = stem,
    build = build,
    pdf_name = filename or (stem .. '.pdf'),
    aux_dir = dir(build.auxDirectory or auxdir or outdir or settings.auxDirectory),
    log_dir = dir(build.logDirectory or auxdir or outdir or settings.auxDirectory),
    pdf_dir = dir(build.pdfDirectory or outdir or settings.auxDirectory),
  }
end

return M
