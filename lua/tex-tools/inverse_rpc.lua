local M = {}
local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
end

-- Minimal asynchronous MessagePack RPC keeps an unresponsive editor from
-- blocking discovery. Results here contain only plain Lua values.
local function rpc(server, code, args, timeout)
  local host, port = server:match('^([^/\\]+):(%d+)$')
  local socket = host and vim.uv.new_tcp() or vim.uv.new_pipe(false)
  local done, result, message, disconnected = false, nil, nil, false
  local data = ''
  local function connected(err)
    if done then
      return
    end
    if err then
      done, message, disconnected = true, err, true
      return
    end
    socket:read_start(function(read_err, chunk)
      if done then
        return
      end
      if read_err or not chunk then
        done, message = true, read_err or 'RPC connection closed'
        return
      end
      data = data .. chunk
      if #data > 1024 * 1024 then
        done, message = true, 'RPC response is too large'
        return
      end
      local ok, response = pcall(vim.mpack.decode, data)
      if ok and type(response) == 'table' and response[1] == 1 and response[2] == 1 then
        done = true
        if response[3] ~= vim.NIL then
          message = vim.inspect(response[3])
        else
          result = response[4]
        end
      end
    end)
    socket:write(vim.mpack.encode({ 0, 1, 'nvim_exec_lua', { code, args } }), function(write_err)
      if write_err then
        done, message = true, write_err
      end
    end)
  end
  local ok, err = pcall(function()
    if host then
      socket:connect(host, tonumber(port), connected)
    else
      socket:connect(server, connected)
    end
  end)
  if not ok then
    done, message, disconnected = true, err, true
  end
  if not vim.wait(timeout, function()
    return done
  end, 10) then
    message = 'RPC request timed out'
  end
  done = true
  socket:read_stop()
  socket:close()
  return result, message, disconnected
end

local function dispatch(directory, file, line, point)
  file = canonical(file)
  local scan = vim.uv.fs_scandir(directory)
  local matches = {}
  while scan do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if kind == 'file' and name:match('^%x+%.json$') then
      local path = vim.fs.joinpath(directory, name)
      local ok, record = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
      end)
      if
        ok
        and type(record) == 'table'
        and type(record.server) == 'string'
        and type(record.token) == 'string'
        and type(record.pid) == 'number'
        and record.pid > 0
        and record.pid % 1 == 0
        and record.pid <= 2147483647
      then
        local alive = vim.uv.kill(record.pid, 0)
        if not alive then
          vim.uv.fs_unlink(path)
        else
          local score, _, disconnected = rpc(
            record.server,
            point and 'return require("tex-tools.inverse").score_pdf(...)'
              or 'return require("tex-tools.inverse").score(...)',
            { file, record.token },
            500
          )
          if disconnected then
            vim.uv.fs_unlink(path)
          end
          if
            type(score) == 'table'
            and type(score.priority) == 'number'
            and type(score.depth) == 'number'
            and type(score.active) == 'number'
          then
            matches[#matches + 1] = { server = record.server, token = record.token, score = score }
          end
        end
      end
    end
  end
  table.sort(matches, function(a, b)
    for _, key in ipairs({ 'priority', 'depth', 'active' }) do
      if a.score[key] ~= b.score[key] then
        return a.score[key] > b.score[key]
      end
    end
    return a.server < b.server
  end)
  for _, match in ipairs(matches) do
    -- Recheck eligibility before opening, in case a project closed meanwhile.
    local result, err = rpc(
      match.server,
      point and 'return {require("tex-tools.inverse").search_pdf(...)}'
        or 'local file, line, token = ...; if not require("tex-tools.inverse").score(file, token) then return {false} end; return {require("tex-tools.viewer").inverse_search(file, line)}',
      point and { file, line, point.x, point.y, match.token } or { file, line, match.token },
      2000
    )
    if result == nil then
      return false, 'Inverse search failed: ' .. tostring(err)
    end
    if type(result) == 'table' and result[1] == true then
      return true
    end
  end
  return false,
    point and 'No responsive Neovim session has registered this PDF; open or forward-search it from tex-tools first'
      or 'No responsive Neovim session has this source open or a matching texlab workspace'
end

function M.dispatch(directory, file, line)
  if type(file) ~= 'string' or file == '' or not line or line < 1 or line % 1 ~= 0 or line == math.huge then
    return false, 'Expected a source file and a positive line number'
  end
  return dispatch(directory, file, line)
end

function M.dispatch_position(directory, file, page, x, y)
  local function finite(n)
    return type(n) == 'number' and n >= 0 and n < math.huge
  end
  if
    type(directory) ~= 'string'
    or type(file) ~= 'string'
    or file == ''
    or not finite(page)
    or page < 1
    or page % 1 ~= 0
    or not finite(x)
    or not finite(y)
  then
    return false, 'Expected a PDF, positive page and finite nonnegative coordinates'
  end
  return dispatch(directory, file, page, { x = x, y = y })
end

return M
