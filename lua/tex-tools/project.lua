local M = {}
local mains = setmetatable({}, { __mode = 'k' })

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
  local configured = opts.main_file
  if configured == nil then
    configured = mains[client] or require('tex-tools.config').options.build.main_file
  end
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
  local layout = M.backend(build) == 'latexmk' and require('tex-tools.latexmk').resolve(build, cwd, file) or nil
  cwd = layout and layout.cwd or cwd
  local stem = layout and layout.stem or vim.fs.basename(file):sub(1, -5)
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
    aux_dir = dir(build.auxDirectory or settings.auxDirectory or (layout and layout.aux_dir) or auxdir or outdir),
    log_dir = dir(build.logDirectory or settings.auxDirectory or (layout and layout.aux_dir) or auxdir or outdir),
    pdf_dir = dir(build.pdfDirectory or settings.auxDirectory or (layout and layout.pdf_dir) or outdir),
    artifact_source = layout and 'latexmk' or 'settings',
    main_source = mains[client] and 'session' or (configured and 'configuration' or 'source'),
  }
end

function M.explicit(client)
  return mains[client] or require('tex-tools.config').options.build.main_file or nil
end

function M.attach(client, path)
  local bufnr = vim.fn.bufnr(path)
  if vim.lsp.get_client_by_id(client.id) == client then
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    if not vim.lsp.buf_attach_client(bufnr, client.id) then
      return nil, 'Could not attach the main document to texlab'
    end
  end
  return bufnr >= 0 and bufnr or nil
end

local function change(client, path)
  local manager = require('tex-tools.build')
  if manager.active(client) or manager.state(client).cleaning then
    return false, 'Wait for compilation or cleaning to finish before changing the main file'
  end
  if path == false then
    mains[client] = nil
    local project = M.resolve(client)
    return true, project and project.main_file or nil
  end
  if type(path) ~= 'string' or path == '' or path:find('%z') then
    return false, 'Provide a nonempty .tex path'
  end
  local project, err = M.resolve(client, { main_file = path })
  if not project then
    return false, err
  end
  mains[client] = project.main_file
  return true, project.main_file
end

function M.main_file(path)
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  if path ~= nil then
    return change(client, path)
  end
  local project
  project, err = M.resolve(client)
  return project ~= nil, project and project.main_file or err
end

function M.command(path)
  if path == 'select' then
    local client, err = require('tex-tools.lsp').client()
    if not client then
      return false, err
    end
    local project = M.resolve(client)
    vim.ui.input(
      { prompt = 'Main .tex file: ', default = project and project.main_file or '', completion = 'file' },
      function(value)
        if value and value ~= '' then
          local ok, result = change(client, value)
          vim.notify(
            ok and ('Main file: ' .. result) or result,
            ok and vim.log.levels.INFO or vim.log.levels.WARN,
            { title = 'tex-tools' }
          )
        end
      end
    )
    return true
  end
  if path == 'reset' then
    path = false
  end
  local ok, result = M.main_file(path)
  if ok then
    vim.notify(
      result and ('Main file: ' .. result) or 'Main-file override cleared',
      vim.log.levels.INFO,
      { title = 'tex-tools' }
    )
  end
  return ok, result
end

function M.info()
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return nil, err
  end
  local project
  project, err = M.resolve(client)
  if not project then
    return nil, err
  end
  local compiler = require('tex-tools.compiler').snapshot(client)
  project.client_id, project.root_dir = client.id, (client.config or {}).root_dir
  project.compiler, project.profile = compiler.executable, compiler.profile
  project.build = vim.deepcopy(project.build)
  project.log_file = vim.fs.joinpath(project.log_dir, project.stem .. '.log')
  project.pdf_file = vim.fs.joinpath(project.pdf_dir, project.pdf_name)
  project.synctex_file = vim.fs.joinpath(project.pdf_dir, project.stem .. '.synctex.gz')
  return project
end

function M.show_info()
  local info, err = M.info()
  if not info then
    return false, err
  end
  local lines = {
    'texlab client: ' .. info.client_id,
    'Main: ' .. info.main_file .. ' (' .. info.main_source .. ')',
    'LSP root: ' .. (info.root_dir or '(unset)'),
    'Working directory: ' .. info.cwd,
    'Compiler: ' .. info.compiler .. (info.profile and (' [' .. info.profile .. ']') or ''),
    'Arguments: ' .. vim.inspect(info.build.args),
    'Auxiliary directory: ' .. info.aux_dir,
    'Log: ' .. info.log_file,
    'PDF: ' .. info.pdf_file,
    'SyncTeX: ' .. info.synctex_file,
  }
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'tex-tools' })
  return true
end

return M
