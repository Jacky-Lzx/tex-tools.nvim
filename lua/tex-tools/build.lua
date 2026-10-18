local M = {}
local states = setmetatable({}, { __mode = 'k' })
local installed = false
local outcomes = { [0] = 'succeeded', [1] = 'failed', [2] = 'failed_to_start', [3] = 'cancelled' }

function M.state(client)
  if not states[client] then
    states[client] = { phase = 'idle', generation = 0, client_id = client.id }
  end
  return states[client]
end

function M.begin(client, uri)
  local state = M.state(client)
  state.generation = state.generation + 1
  state.phase, state.uri, state.result = 'requested', uri, nil
  state.error = nil
  state.started_at, state.finished_at = vim.uv.hrtime(), nil
  state.request_id, state.token, state.cancelling = nil, nil, nil
  state.output_lines = {}
  if package.loaded['tex-tools.build_output'] then
    package.loaded['tex-tools.build_output'].changed(state)
  end
  return state.generation
end

function M.finish(client, generation, code, error_message)
  local state = M.state(client)
  if state.generation ~= generation then
    return
  end
  state.phase = error_message and 'failed' or (outcomes[code] or 'unknown')
  state.result, state.error = code, error_message
  state.finished_at, state.request_id = vim.uv.hrtime(), nil
end

function M.active(client)
  local phase = M.state(client).phase
  return phase == 'requested' or phase == 'running' or phase == 'cancelling'
end

function M.progress(client, params)
  if type(params) ~= 'table' or type(params.value) ~= 'table' then
    return
  end
  local state, value = M.state(client), params.value
  if value.kind == 'begin' and value.title == 'Building' then
    if state.phase ~= 'requested' then
      M.begin(client, value.message)
    end
    state.phase, state.token = 'running', params.token
  elseif params.token ~= nil and params.token == state.token and value.kind == 'end' then
    if M.active(client) then
      state.phase = state.cancelling and 'cancelled' or 'finished'
    end
    state.finished_at, state.token = vim.uv.hrtime(), nil
  end
end

function M.attach(client)
  local state = M.state(client)
  client.handlers = client.handlers or {}
  if not state.output_wrapper then
    local previous = client.handlers['window/logMessage']
    state.output_wrapper = function(err, params, ctx, config)
      if
        not err
        and type(params) == 'table'
        and params.type == vim.lsp.protocol.MessageType.Log
        and type(params.message) == 'string'
      then
        require('tex-tools.build_output').append(state, params.message)
      end
      local handler = previous or vim.lsp.handlers['window/logMessage']
      if handler then
        return handler(err, params, ctx, config)
      end
    end
    client.handlers['window/logMessage'] = state.output_wrapper
  end
  if not installed then
    installed = true
    local group = vim.api.nvim_create_augroup('TexToolsBuild', { clear = true })
    vim.api.nvim_create_autocmd('LspProgress', {
      group = group,
      callback = function(event)
        local data = event.data or {}
        local source = vim.lsp.get_client_by_id(data.client_id)
        if source and source.name == 'texlab' then
          M.progress(source, data.params)
        end
      end,
    })
  end
end

function M.snapshot(client)
  local state = M.state(client)
  local result = {
    client_id = client.id,
    phase = state.phase,
    uri = state.uri,
    result = state.result,
    error = state.error,
    on_save = (((client.settings or {}).texlab or {}).build or {}).onSave == true,
  }
  if state.started_at then
    result.elapsed = ((state.finished_at or vim.uv.hrtime()) - state.started_at) / 1e9
  end
  return result
end

return M
