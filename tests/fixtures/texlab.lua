-- A small stdio LSP peer used to verify the real Neovim transport and handlers.
local function send(message)
  local body = vim.json.encode(message)
  io.stdout:write(('Content-Length: %d\r\n\r\n'):format(#body), body)
  io.stdout:flush()
end
local function notify(method, params)
  send({ jsonrpc = '2.0', method = method, params = params })
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
          executeCommandProvider = { commands = { 'texlab.cancelBuild' } },
        },
      },
    })
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
