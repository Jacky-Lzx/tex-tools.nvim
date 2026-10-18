local M = {}
local source = vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))
local callback_script =
  vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))), 'scripts', 'inverse-search.lua')

local function join(argv)
  return table.concat(
    vim.tbl_map(function(value)
      return "'" .. value:gsub("'", "'\\''") .. "'"
    end, argv),
    ' '
  )
end

function M.callback(kind)
  if kind ~= 'skim' and kind ~= 'zathura' then
    return nil, 'Choose skim or zathura for inverse search'
  end
  if vim.fn.has('win32') == 1 then
    return nil, 'Generated viewer callbacks currently require POSIX argument quoting'
  end
  local server = vim.v.servername
  if server == '' then
    local ok, result = pcall(vim.fn.serverstart)
    if not ok or result == '' then
      return nil, 'Could not start a Neovim RPC server: ' .. tostring(result)
    end
    server = result
  end
  local argv = {
    vim.v.progpath,
    '--headless',
    '--clean',
    '-i',
    'NONE',
    '-n',
    '-l',
    callback_script,
    server,
    kind == 'skim' and '%line' or '%{line}',
    kind == 'skim' and '%file' or '%{input}',
  }
  -- Skim substitutes into a shell command and escapes double-quote contents.
  -- Single-quoted %file disables its escaping and breaks apostrophe paths.
  -- Zathura instead splits arguments first and substitutes afterwards.
  local arguments = kind == 'skim' and (join(vim.list_slice(argv, 2, #argv - 2)) .. ' "%line" "%file"')
    or join(vim.list_slice(argv, 2))
  return {
    command = argv[1],
    arguments = arguments,
    argv = argv,
    shell_command = join({ argv[1] }) .. ' ' .. arguments,
    server = server,
  }
end

function M.show_callback(kind)
  local result, err = M.callback(kind or 'skim')
  if not result then
    return false, err
  end
  local lines = kind == 'zathura' and { 'Zathura synctex-editor-command:', result.shell_command }
    or { 'Skim > Settings > Sync > Preset: Custom', 'Command: ' .. result.command, 'Arguments: ' .. result.arguments }
  lines[#lines + 1] = 'This callback targets this Neovim session; regenerate it after restarting Neovim.'
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO, { title = 'tex-tools' })
  return true
end

function M.inverse_search(file, line, column)
  line, column = tonumber(line), tonumber(column or 1)
  if
    type(file) ~= 'string'
    or file == ''
    or file:find('%z')
    or not line
    or line < 1
    or line % 1 ~= 0
    or not column
    or column < 1
    or column % 1 ~= 0
    or line == math.huge
    or column == math.huge
  then
    return false, 'Inverse search requires a file and positive line/column numbers'
  end
  file = vim.fs.normalize(vim.fs.abspath(file), { expand_env = false })
  local stat = vim.uv.fs_stat(file)
  if not stat or stat.type ~= 'file' then
    return false, 'Inverse-search source is unreadable: ' .. file
  end
  local bufnr = vim.fn.bufadd(file)
  vim.fn.bufload(bufnr)
  local win = vim.fn.win_findbuf(bufnr)[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    if vim.bo.modified and not vim.o.hidden then
      vim.cmd.split()
    end
    vim.api.nvim_set_current_buf(bufnr)
  end
  line = math.min(line, vim.api.nvim_buf_line_count(bufnr))
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
  local col = math.min(column - 1, math.max(0, #text - 1))
  while col > 0 and (text:byte(col + 1) or 0) >= 128 and (text:byte(col + 1) or 0) < 192 do
    col = col - 1
  end
  vim.api.nvim_win_set_cursor(0, { line, col })
  vim.cmd.normal({ 'zvzz', bang = true })
  vim.api.nvim_exec_autocmds(
    'User',
    { pattern = 'TexToolsInverseSearch', data = { file = file, line = line, column = col + 1 } }
  )
  return true
end

function M.detect(client)
  local options = require('tex-tools.config').options.viewer
  local method = options.method
  local forward = ((((client or {}).settings or {}).texlab or {}).forwardSearch or {})
  if method == 'auto' then
    local name = vim.fs.basename(forward.executable or '')
    if name == 'displayline' then
      method = 'skim'
    elseif name == 'zathura' or vim.fn.executable('zathura') == 1 then
      method = 'zathura'
    else
      method = 'generic'
    end
  end
  local executable = options.executable
  if not executable then
    executable = method == 'zathura' and 'zathura'
      or (vim.fn.has('mac') == 1 and 'open' or (vim.fn.has('win32') == 1 and 'explorer.exe' or 'xdg-open'))
    if method == 'zathura' and vim.fs.basename(forward.executable or '') == 'zathura' then
      executable = forward.executable
    end
  end
  return { method = method, executable = executable, args = vim.deepcopy(options.args) }
end

local function start(argv, cwd)
  if vim.fn.executable(argv[1]) ~= 1 then
    return false, 'PDF viewer executable is unavailable: ' .. argv[1]
  end
  local id = vim.fn.jobstart(argv, {
    cwd = cwd,
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          vim.notify('PDF viewer exited with status ' .. code, vim.log.levels.WARN, { title = 'tex-tools' })
        end)
      end
    end,
  })
  return id > 0, id > 0 and id or 'Could not start the PDF viewer'
end

function M.view()
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  local info
  info, err = require('tex-tools.project').info()
  if not info then
    return false, err
  end
  if vim.fn.filereadable(info.pdf_file) ~= 1 then
    return false, 'PDF does not exist; compile first: ' .. info.pdf_file
  end
  local viewer = M.detect(client)
  local argv = { viewer.executable }
  vim.list_extend(argv, viewer.args)
  if viewer.method == 'zathura' then
    local callback
    callback, err = M.callback('zathura')
    if not callback then
      return false, err
    end
    vim.list_extend(argv, { '--synctex-editor-command', callback.shell_command })
  elseif viewer.method == 'skim' then
    vim.list_extend(argv, { '-a', 'Skim' })
  end
  argv[#argv + 1] = info.pdf_file
  return start(argv, info.cwd)
end

-- texlab's forwardSearch request cannot express a session main-file override.
-- In that case expand its existing viewer arguments against our resolved PDF.
function M.forward_search(client)
  local info, err = require('tex-tools.project').info()
  if not info then
    return false, err
  end
  if vim.fn.filereadable(info.pdf_file) ~= 1 then
    return false, 'Compile the selected main file first: ' .. info.pdf_file
  end
  local forward = (((client.settings or {}).texlab or {}).forwardSearch or {})
  local file = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if forward.executable and type(forward.args) == 'table' then
    local replacements = { p = info.pdf_file, f = file, l = tostring(line) }
    local argv = { forward.executable }
    for _, value in ipairs(forward.args) do
      argv[#argv + 1] = value:gsub('%%([pfl])', replacements)
    end
    return start(argv, info.cwd)
  end
  return false, 'Configure texlab.forwardSearch executable/args for forward search with a selected main file'
end

return M
