-- Invoked with: nvim --headless --clean -i NONE -n -l SCRIPT SERVER LINE FILE
-- Keep filenames in RPC arguments, never in generated Lua or Ex commands.
local server, line, file = arg[1], tonumber(arg[2]), arg[3]
local function fail(message)
  io.stderr:write('tex-tools inverse search: ' .. tostring(message) .. '\n')
  vim.cmd('cquit 1')
end
if not server or not line or not file then
  fail('expected SERVER LINE FILE')
end
local kind = server:match('^[^/\\]+:%d+$') and 'tcp' or 'pipe'
local channel = vim.fn.sockconnect(kind, server, { rpc = true })
if channel == 0 then
  fail('could not connect to the Neovim session')
end
local ok, result = pcall(
  vim.rpcrequest,
  channel,
  'nvim_exec_lua',
  'return { require("tex-tools.viewer").inverse_search(...) }',
  { file, line }
)
vim.fn.chanclose(channel)
if not ok then
  fail(result)
end
if not result[1] then
  fail(result[2] or 'source jump failed')
end
vim.cmd('qa!')
