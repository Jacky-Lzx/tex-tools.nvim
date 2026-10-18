-- Keep texlab's log reader in step with latexmk's effective artifact directory.
-- Managed values are excluded from project/profile resolution so they never
-- become stale user overrides when the rc file or compiler changes.
local M = {}
local managed, pending = setmetatable({}, { __mode = 'k' }), setmetatable({}, { __mode = 'k' })
local installed = false

local function raw_build(client)
  return (((client.settings or {}).texlab or {}).build or {})
end

local function owned(client)
  local record = managed[client]
  if record and raw_build(client).logDirectory ~= record.value then
    managed[client] = nil -- A user/configuration update replaced our value.
    return nil
  end
  return record
end

function M.build_settings(client)
  local build = raw_build(client)
  local record = owned(client)
  if record then
    build = vim.tbl_extend('force', {}, build)
    build.logDirectory = record.original
  end
  return build
end

function M.forget(client)
  managed[client] = nil
end

local function tex_buffer(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_loaded(bufnr)
    and vim.tbl_contains({ 'tex', 'plaintex' }, vim.bo[bufnr].filetype)
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

local function source_buffer(client, bufnr)
  if tex_buffer(bufnr) then
    return bufnr
  end
  for attached in pairs(client.attached_buffers or {}) do
    if tex_buffer(attached) then
      return attached
    end
  end
end

function M.sync(client, bufnr)
  if client.name ~= 'texlab' or not client.initialized then
    return true
  end
  bufnr = source_buffer(client, bufnr)
  if not bufnr then
    return true
  end
  local build, record = raw_build(client), owned(client)
  local explicit = build.logDirectory
  if not record and type(explicit) == 'string' and explicit ~= '' then
    return true
  end
  local project = require('tex-tools.project').resolve(client, { bufnr = bufnr })
  if not project then
    return true
  end
  local directory = project.artifact_source == 'latexmk' and project.log_dir or nil
  if not directory and not record then
    return true
  end
  local value = directory or (record and record.original)
  if build.logDirectory == value then
    return true
  end
  local previous = client.settings
  local settings = vim.deepcopy(previous or {})
  settings.texlab = settings.texlab or {}
  settings.texlab.build = settings.texlab.build or {}
  settings.texlab.build.logDirectory = value
  client.settings = settings
  local ok, accepted = pcall(client.notify, client, 'workspace/didChangeConfiguration', { settings = settings })
  if not ok or not accepted then
    client.settings = previous
    return false, ok and 'texlab rejected the log-directory update' or tostring(accepted)
  end
  local original = explicit
  if record then
    original = record.original
  end
  managed[client] = directory and { value = directory, original = original } or nil
  return true
end

function M.schedule(client, bufnr)
  if not client.initialized then
    return
  end
  if pending[client] then
    if tex_buffer(bufnr) then
      pending[client].bufnr = bufnr
    end
    return
  end
  pending[client] = { bufnr = bufnr }
  vim.schedule(function()
    local request = pending[client]
    pending[client] = nil
    if vim.lsp.get_client_by_id(client.id) ~= client then
      return
    end
    local ok, err = M.sync(client, request.bufnr)
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'tex-tools' })
    end
  end)
end

function M.attach(client, bufnr)
  if not installed then
    installed = true
    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'BufFilePost' }, {
      group = vim.api.nvim_create_augroup('TexToolsDiagnostics', { clear = true }),
      callback = function(event)
        if tex_buffer(event.buf) then
          for _, source in ipairs(vim.lsp.get_clients({ name = 'texlab', bufnr = event.buf })) do
            M.schedule(source, event.buf)
          end
        elseif event.event == 'BufWritePost' then
          local path = vim.api.nvim_buf_get_name(event.buf)
          local name = vim.fs.basename(path)
          if name == '.latexmkrc' or name == 'latexmkrc' or require('tex-tools.latexmk').config_file(path) then
            for _, source in ipairs(vim.lsp.get_clients({ name = 'texlab' })) do
              M.schedule(source)
            end
          end
        end
      end,
    })
  end
  M.schedule(client, bufnr)
end

return M
