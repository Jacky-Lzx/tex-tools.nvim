-- Keep registration local to this plugin and snapshot commands once per batch.
local M, owned = {}, {}
local api = vim.api
local function commands(buffer)
  return buffer and api.nvim_buf_get_commands(buffer, {}) or api.nvim_get_commands({})
end

function M.register(entries, buffer)
  if buffer == 0 then
    buffer = api.nvim_get_current_buf()
  end
  local scope = buffer or 0
  owned[scope] = owned[scope] or {}
  local existing = commands(buffer)
  -- Validate the complete set before installing any command.
  for name in pairs(entries) do
    local previous = owned[scope][name]
    assert(
      not existing[name] or previous and vim.deep_equal(existing[name], previous),
      'Command already exists: ' .. name
    )
  end
  for name, entry in pairs(entries) do
    local callback, opts = entry[1], entry[2]
    local action = callback
    if type(callback) == 'function' then
      action = function(args)
        return callback(args)
      end
    end
    opts = vim.tbl_extend('force', {}, opts or {}, { force = existing[name] ~= nil })
    if buffer then
      api.nvim_buf_create_user_command(buffer, name, action, opts)
    else
      api.nvim_create_user_command(name, action, opts)
    end
  end
  local installed, cleanups = commands(buffer), {}
  for name in pairs(entries) do
    local record = installed[name]
    owned[scope][name] = record
    cleanups[name] = function()
      if buffer and not api.nvim_buf_is_valid(buffer) then
        return
      end
      if owned[scope] and owned[scope][name] == record and vim.deep_equal(commands(buffer)[name], record) then
        M.delete(name, buffer)
      end
    end
  end
  return cleanups
end

function M.create(name, callback, opts, buffer)
  return M.register({ [name] = { callback, opts } }, buffer)[name]
end

function M.delete(name, buffer)
  if buffer == 0 then
    buffer = api.nvim_get_current_buf()
  end
  local scope = buffer or 0
  local installed = owned[scope] and owned[scope][name]
  if
    installed
    and (not buffer or api.nvim_buf_is_valid(buffer))
    and vim.deep_equal(commands(buffer)[name], installed)
  then
    if buffer then
      api.nvim_buf_del_user_command(buffer, name)
    else
      api.nvim_del_user_command(name)
    end
  end
  if owned[scope] then
    owned[scope][name] = nil
  end
end

api.nvim_create_autocmd('BufWipeout', {
  callback = function(event)
    owned[event.buf] = nil
  end,
})
return M
