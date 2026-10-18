-- Stable form: nvim --headless --clean -i NONE -n -l SCRIPT --registry DIRECTORY LINE FILE
-- The earlier SCRIPT SERVER LINE FILE form remains supported.
-- Keep filenames in RPC arguments, never in generated Lua or Ex commands.
local server, line, file = arg[1], tonumber(arg[2]), arg[3]
local function fail(message)
  io.stderr:write('tex-tools inverse search: ' .. tostring(message) .. '\n')
  vim.cmd('cquit 1')
end
if not server or (server ~= '--registry' and (not line or not file)) then
  fail('expected SERVER LINE FILE')
end
if server == '--registry' then
  local directory = arg[2]
  line, file = tonumber(arg[3]), arg[4]
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, 'S').source:sub(2))))
  vim.opt.runtimepath:prepend(root)
  local ok, err = require('tex-tools.inverse_rpc').dispatch(directory, file, line)
  if not ok then
    fail(err)
  end
  vim.cmd('qa!')
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
