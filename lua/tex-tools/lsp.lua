local M = {}

local status = {
  build = { [0] = 'Build succeeded', [1] = 'Build failed', [2] = 'Build could not start', [3] = 'Build cancelled' },
  forward = {
    [0] = 'Forward search succeeded',
    [1] = 'Forward search failed',
    [2] = 'Forward search could not start',
    [3] = 'Configure texlab.forwardSearch first',
  },
}

local function request(action, method)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'texlab' })[1]
  if not client then
    return false, 'No texlab client attached to this buffer'
  end
  if vim.api.nvim_buf_get_name(bufnr) == '' then
    return false, 'Save this buffer to a .tex file first'
  end
  if action == 'build' and vim.bo[bufnr].modified then
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd.update()
    end)
    if not ok then
      return false, tostring(err)
    end
  end
  local params = action == 'build' and { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    or vim.lsp.util.make_position_params(0, client.offset_encoding)
  local accepted, id = client:request(method, params, function(err, result)
    if err then
      vim.notify(err.message or tostring(err), vim.log.levels.ERROR, { title = 'tex-tools' })
      return
    end
    local code = type(result) == 'table' and result.status or nil
    local message = status[action][code] or 'Unexpected response from texlab'
    vim.notify(message, code == 0 and vim.log.levels.INFO or vim.log.levels.WARN, { title = 'tex-tools' })
  end, bufnr)
  if not accepted then
    return false, 'texlab rejected the request'
  end
  return true, id
end

function M.build()
  return request('build', 'textDocument/build')
end

function M.forward_search()
  return request('forward', 'textDocument/forwardSearch')
end

return M
