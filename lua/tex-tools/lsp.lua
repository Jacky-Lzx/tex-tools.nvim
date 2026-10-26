-- Dispatch only to the selected server; never mix protocols in one buffer.
local M = {}

function M.backend()
  return require('tex-tools.config').options.lsp
end

function M.matches(client)
  if M.backend() == 'texlab' then
    return client.name == 'texlab'
  end
  return client.name == 'latex_lsp' or client.name == 'latex-lsp'
end

function M.clients(bufnr)
  if M.backend() == 'texlab' then
    return vim.lsp.get_clients({ bufnr = bufnr, name = 'texlab' })
  end
  return vim.tbl_filter(M.matches, vim.lsp.get_clients({ bufnr = bufnr }))
end

function M.attach(client, bufnr)
  if M.backend() == 'texlab' then
    return require('tex-tools.build').attach(client, bufnr)
  end
  return require('tex-tools.lsp.latex').attach(client)
end

function M.client(bufnr)
  local client = M.clients(bufnr or vim.api.nvim_get_current_buf())[1]
  if not client then
    return nil, 'No ' .. M.backend() .. ' client attached to this buffer'
  end
  M.attach(client, bufnr)
  return client
end

function M.execute(client, command, arguments, callback)
  local provider = (client.server_capabilities or {}).executeCommandProvider
  if
    (M.backend() == 'latex-lsp' and not provider)
    or (provider and provider.commands and not vim.tbl_contains(provider.commands, command))
  then
    return false, 'The attached ' .. M.backend() .. ' server does not support ' .. command
  end
  local accepted, id = client:request('workspace/executeCommand', {
    command = command,
    arguments = arguments or {},
  }, callback or function(err)
    if err then
      vim.notify(err.message or tostring(err), vim.log.levels.ERROR, { title = 'tex-tools' })
    end
  end, vim.api.nvim_get_current_buf())
  if not accepted then
    return false, M.backend() .. ' rejected the request'
  end
  return true, id
end

for _, method in ipairs({
  'build',
  'forward_search',
  'cancel_build',
  'cancel_all_builds',
  'build_status',
  'show_build_status',
  'build_on_save',
}) do
  M[method] = function(...)
    local module = M.backend() == 'texlab' and 'texlab' or 'latex'
    return require('tex-tools.lsp.' .. module)[method](...)
  end
end

return M
