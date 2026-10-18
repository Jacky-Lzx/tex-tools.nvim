local M = {}

function M.client()
  local client = vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), name = 'texlab' })[1]
  if not client then
    return nil, 'No texlab client attached to this buffer'
  end
  require('tex-tools.build').attach(client)
  return client
end

function M.execute(client, command, arguments, callback)
  local provider = (client.server_capabilities or {}).executeCommandProvider
  if provider and provider.commands and not vim.tbl_contains(provider.commands, command) then
    return false, 'The attached texlab server does not support ' .. command
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
    return false, 'texlab rejected the request'
  end
  return true, id
end

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
  local client, client_err = M.client()
  if not client then
    return false, client_err
  end
  if vim.api.nvim_buf_get_name(bufnr) == '' then
    return false, 'Save this buffer to a .tex file first'
  end
  local manager, generation
  if action == 'build' then
    manager = require('tex-tools.build')
    if manager.active(client) then
      return false, 'A build is already running in this texlab client; cancel it before starting another'
    end
  end
  local modified = vim.bo[bufnr].modified
  if action == 'build' and modified then
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd.update()
    end)
    if not ok then
      return false, tostring(err)
    end
  end
  if manager then
    generation = manager.begin(client, vim.uri_from_bufnr(bufnr))
    -- didSave already triggers a build when onSave is enabled. Sending a
    -- second explicit request would queue a duplicate compilation in texlab.
    if modified and manager.snapshot(client).on_save then
      return true
    end
  end
  local params = action == 'build' and { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    or vim.lsp.util.make_position_params(0, client.offset_encoding)
  local accepted, id = client:request(method, params, function(err, result)
    if err then
      if manager then
        manager.finish(client, generation, nil, err.message or tostring(err))
      end
      vim.notify(err.message or tostring(err), vim.log.levels.ERROR, { title = 'tex-tools' })
      return
    end
    local code = type(result) == 'table' and result.status or nil
    if manager then
      manager.finish(client, generation, code)
    end
    local message = status[action][code] or 'Unexpected response from texlab'
    vim.notify(message, code == 0 and vim.log.levels.INFO or vim.log.levels.WARN, { title = 'tex-tools' })
  end, bufnr)
  if not accepted then
    if manager then
      manager.finish(client, generation, nil, 'texlab rejected the request')
    end
    return false, 'texlab rejected the request'
  end
  if manager and manager.active(client) then
    manager.state(client).request_id = id
  end
  return true, id
end

function M.build()
  return request('build', 'textDocument/build')
end

function M.forward_search()
  return request('forward', 'textDocument/forwardSearch')
end

function M.cancel_build()
  local client, err = M.client()
  if not client then
    return false, err
  end
  local manager = require('tex-tools.build')
  local generation = manager.state(client).generation
  return M.execute(client, 'texlab.cancelBuild', {}, function(error)
    if error then
      vim.notify(error.message or tostring(error), vim.log.levels.ERROR, { title = 'tex-tools' })
    elseif manager.active(client) and manager.state(client).generation == generation then
      local state = manager.state(client)
      state.phase, state.cancelling = 'cancelling', true
    end
  end)
end

function M.cancel_all_builds()
  local clients = vim.lsp.get_clients({ name = 'texlab' })
  if #clients == 0 then
    return false, 'No texlab clients are running'
  end
  local failures = {}
  for _, client in ipairs(clients) do
    local generation = require('tex-tools.build').state(client).generation
    local ok, err = M.execute(client, 'texlab.cancelBuild', {}, function(error)
      if error then
        vim.notify(error.message or tostring(error), vim.log.levels.ERROR, { title = 'tex-tools' })
      elseif
        require('tex-tools.build').active(client)
        and require('tex-tools.build').state(client).generation == generation
      then
        local state = require('tex-tools.build').state(client)
        state.phase, state.cancelling = 'cancelling', true
      end
    end)
    if not ok then
      failures[#failures + 1] = tostring(err)
    end
  end
  return #failures == 0, #failures > 0 and table.concat(failures, '\n') or nil
end

function M.build_status()
  local client, err = M.client()
  if not client then
    return nil, err
  end
  return require('tex-tools.build').snapshot(client)
end

function M.show_build_status()
  local snapshot, err = M.build_status()
  if not snapshot then
    return false, err
  end
  local message = ('Build: %s; build on save: %s'):format(snapshot.phase, snapshot.on_save and 'on' or 'off')
  if snapshot.elapsed then
    message = message .. ('; %.1fs'):format(snapshot.elapsed)
  end
  if snapshot.uri then
    message = message .. '\n' .. snapshot.uri
  end
  vim.notify(message, vim.log.levels.INFO, { title = 'tex-tools' })
  return true
end

function M.build_on_save(enabled)
  if enabled ~= nil then
    vim.validate('enabled', enabled, 'boolean')
  end
  local client, err = M.client()
  if not client then
    return false, err
  end
  client.settings = client.settings or {}
  client.settings.texlab = client.settings.texlab or {}
  client.settings.texlab.build = client.settings.texlab.build or {}
  local build = client.settings.texlab.build
  local previous = build.onSave
  if enabled == nil then
    enabled = not previous
  end
  build.onSave = enabled
  if not client:notify('workspace/didChangeConfiguration', { settings = client.settings }) then
    build.onSave = previous
    return false, 'texlab rejected the configuration change'
  end
  return true, build.onSave
end

return M
