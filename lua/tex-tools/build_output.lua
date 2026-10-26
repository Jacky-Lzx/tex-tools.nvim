local M = {}

function M.changed(state)
  if state.output_scheduled or not state.output_buffer or not vim.api.nvim_buf_is_valid(state.output_buffer) then
    return
  end
  state.output_scheduled = true
  vim.schedule(function()
    state.output_scheduled = nil
    local bufnr = state.output_buffer
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, state.output_lines or {})
    vim.bo[bufnr].modifiable = false
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      if state.output_follow then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
      end
    end
  end)
end

function M.append(state, message)
  state.output_lines = state.output_lines or {}
  message = message:gsub('\27%[[%d;?]*[%a]', ''):gsub('\r\n', '\n'):gsub('\r', '')
  local lines = vim.split(message, '\n', { plain = true })
  if #lines > 1 and lines[#lines] == '' then
    table.remove(lines)
  end
  for _, line in ipairs(lines) do
    state.output_lines[#state.output_lines + 1] = vim.fn.strcharpart(line, 0, 8192)
  end
  local limit = require('tex-tools.config').options.build.output_lines
  if #state.output_lines > limit then
    state.output_lines = vim.list_slice(state.output_lines, #state.output_lines - limit + 1)
  end
  M.changed(state)
end

function M.open()
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  local state = require('tex-tools.build').state(client)
  if not state.output_buffer or not vim.api.nvim_buf_is_valid(state.output_buffer) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    state.output_buffer = bufnr
    vim.api.nvim_buf_set_name(bufnr, 'tex-tools://build/' .. tostring(client.id))
    vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = 'wipe', false
    vim.bo[bufnr].filetype, vim.bo[bufnr].undolevels = 'log', -1
    vim.bo[bufnr].modifiable = false
    vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = bufnr, silent = true, desc = 'Close build output' })
    vim.keymap.set('n', 'F', function()
      state.output_follow = not state.output_follow
    end, { buffer = bufnr, desc = 'Toggle following build output' })
  end
  state.output_follow = true
  local win = vim.fn.bufwinid(state.output_buffer)
  if win == -1 then
    vim.cmd('botright 12split')
    vim.api.nvim_win_set_buf(0, state.output_buffer)
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.wo.wrap, vim.wo.number, vim.wo.relativenumber = false, false, false
  M.changed(state)
  return true, state.output_buffer
end

function M.log(path)
  if not path or path == '' then
    local client, err = require('tex-tools.lsp').client()
    if not client then
      return false, err
    end
    local project
    project, err = require('tex-tools.project').info()
    if not project then
      return false, err
    end
    path = project.log_file
    if not path then
      return false, 'No build log reported by the server; compile first'
    end
  end
  path = vim.fs.abspath(path)
  if vim.fn.filereadable(path) ~= 1 then
    return false, 'Build log not found: ' .. path
  end
  vim.api.nvim_cmd({ cmd = 'sview', args = { path }, magic = { file = false, bar = false } }, {})
  vim.bo.autoread = true
  return true, path
end

function M.errors(opts)
  opts = opts or {}
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  local diagnostics = {}
  local modes = { false }
  if (client.server_capabilities or {}).diagnosticProvider then
    modes[#modes + 1] = true
  end
  for _, pull in ipairs(modes) do
    local namespace = vim.lsp.diagnostic.get_namespace(client.id, pull)
    for _, diagnostic in ipairs(vim.diagnostic.get(nil, { namespace = namespace })) do
      if
        diagnostic.severity <= (opts.errors_only and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN)
      then
        diagnostics[#diagnostics + 1] = diagnostic
      end
    end
  end
  local items = vim.diagnostic.toqflist(diagnostics)
  vim.fn.setqflist(
    {},
    ' ',
    { title = 'tex-tools: ' .. require('tex-tools.lsp').backend() .. ' diagnostics', items = items }
  )
  if #items > 0 and opts.open ~= false then
    vim.cmd.copen()
  end
  return true, #items
end

return M
