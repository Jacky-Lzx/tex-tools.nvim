-- A small stdio LSP peer used to verify the real Neovim transport and handlers.
local function send(message)
  local body = vim.json.encode(message)
  io.stdout:write(('Content-Length: %d\r\n\r\n'):format(#body), body)
  io.stdout:flush()
end
local function notify(method, params)
  send({ jsonrpc = '2.0', method = method, params = params })
end
local opened = {}
local settings = {}
local pull = vim.env.TEX_TOOLS_FIXTURE_PULL == '1'
local pending, queries, next_id = {}, {}, 1000
local function pull_settings()
  next_id = next_id + 1
  pending[next_id] = true
  send({
    jsonrpc = '2.0',
    id = next_id,
    method = 'workspace/configuration',
    params = { items = { { section = 'texlab' } } },
  })
end
local function flush_queries()
  if next(pending) == nil then
    for _, id in ipairs(queries) do
      send({ jsonrpc = '2.0', id = id, result = settings })
    end
    queries = {}
  end
end
while true do
  local length
  while true do
    local header = io.stdin:read('*l')
    if not header then
      vim.cmd.qa({ bang = true })
    end
    header = header:gsub('\r$', '')
    if header == '' then
      break
    end
    length = tonumber(header:match('^[Cc]ontent%-[Ll]ength:%s*(%d+)')) or length
  end
  local message = vim.json.decode(io.stdin:read(assert(length)))
  if message.method == 'exit' then
    break
  elseif message.method == 'initialize' then
    send({
      jsonrpc = '2.0',
      id = message.id,
      result = {
        capabilities = {
          textDocumentSync = { openClose = true, change = 1, save = true },
          executeCommandProvider = {
            commands = { 'texlab.cancelBuild', 'texlab.cleanAuxiliary', 'texlab.cleanArtifacts' },
          },
        },
      },
    })
  elseif message.method == 'initialized' and pull then
    pull_settings()
  elseif message.method == nil and pending[message.id] then
    pending[message.id] = nil
    settings = { texlab = message.result and message.result[1] or vim.NIL }
    flush_queries()
  elseif message.method == 'textDocument/didOpen' then
    opened[message.params.textDocument.uri] = true
  elseif message.method == 'workspace/didChangeConfiguration' then
    if pull then
      pull_settings()
    else
      settings = message.params.settings
    end
  elseif message.method == 'tex-tools/fixtureSettings' then
    queries[#queries + 1] = message.id
    flush_queries()
  elseif message.method == 'workspace/executeCommand' and message.params.command:match('^texlab%.clean') then
    local uri = message.params.arguments[1].uri
    if opened[uri] then
      send({ jsonrpc = '2.0', id = message.id, result = vim.NIL })
    else
      send({ jsonrpc = '2.0', id = message.id, error = { code = -32602, message = 'Main document not opened' } })
    end
  elseif message.method == 'textDocument/build' then
    local uri = message.params.textDocument.uri
    send({ jsonrpc = '2.0', id = 100, method = 'window/workDoneProgress/create', params = { token = 'build' } })
    notify('$/progress', { token = 'build', value = { kind = 'begin', title = 'Building', message = uri } })
    notify('window/logMessage', { type = 4, message = 'compiler output: line one' })
    notify('window/logMessage', { type = 4, message = 'compiler output: line two' })
    notify('textDocument/publishDiagnostics', {
      uri = uri,
      diagnostics = {
        {
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
          message = 'fixture compile error',
          severity = 1,
          source = 'texlab',
        },
      },
    })
    notify('$/progress', { token = 'build', value = { kind = 'end' } })
    send({ jsonrpc = '2.0', id = message.id, result = { status = 1 } })
  elseif message.id and message.method then
    send({ jsonrpc = '2.0', id = message.id, result = vim.NIL })
  end
end
vim.cmd.qa({ bang = true })
