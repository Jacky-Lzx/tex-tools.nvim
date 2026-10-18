local M = {}
local record_path, registered_server, token
local pending, stopping = false, false
local active = vim.uv.hrtime()

function M.directory()
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'tex-tools', 'inverse-search')
end

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
end

function M.unregister()
  if record_path then
    vim.uv.fs_unlink(record_path)
  end
  record_path, registered_server, token = nil, nil, nil
end

function M.register()
  if stopping then
    return nil, 'Neovim is exiting'
  end
  local server = vim.v.servername
  if server == '' then
    local ok, result = pcall(vim.fn.serverstart)
    if not ok or result == '' then
      return nil, 'Could not start a Neovim RPC server: ' .. tostring(result)
    end
    server = result
  end
  if record_path and registered_server == server and vim.uv.fs_stat(record_path) then
    return server
  end
  M.unregister()
  local directory = M.directory()
  local ok, err = pcall(vim.fn.mkdir, directory, 'p', 448)
  if not ok then
    return nil, tostring(err)
  end
  token = tostring(vim.fn.getpid()) .. '-' .. tostring(vim.uv.hrtime())
  local path = vim.fs.joinpath(directory, vim.fn.sha256(server .. ':' .. vim.fn.getpid()) .. '.json')
  local temporary = path .. '.' .. vim.fn.getpid() .. '.tmp'
  local fd
  fd, err = vim.uv.fs_open(temporary, 'w', 384)
  if not fd then
    return nil, err
  end
  local data = vim.json.encode({ server = server, pid = vim.fn.getpid(), token = token })
  local written
  written, err = vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
  if written ~= #data then
    vim.uv.fs_unlink(temporary)
    return nil, err or 'Could not write the inverse-search session record'
  end
  ok, err = vim.uv.fs_rename(temporary, path)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, err
  end
  record_path, registered_server = path, server
  local group = vim.api.nvim_create_augroup('TexToolsInverseSession', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      stopping = true
      M.unregister()
    end,
  })
  return server
end

function M.track(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name, ft = vim.api.nvim_buf_get_name(bufnr), vim.bo[bufnr].filetype
  if (ft ~= 'tex' and ft ~= 'plaintex') or name == '' or name:match('^%w+://') then
    return
  end
  active = vim.uv.hrtime()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    if stopping then
      return
    end
    -- One record per process; no project lists or per-buffer disk writes.
    if not record_path or registered_server ~= vim.v.servername then
      local server, err = M.register()
      if not server then
        vim.notify(
          'Inverse search registration failed: ' .. tostring(err),
          vim.log.levels.WARN,
          { title = 'tex-tools' }
        )
      end
    end
  end)
end

-- Query live editor state without loading files or moving the cursor.
function M.score(file, expected_token)
  if not token or expected_token ~= token then
    return nil
  end
  file = canonical(file)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and not name:match('^%w+://') and canonical(name) == file then
        return { priority = 2, depth = 0, active = active }
      end
    end
  end
  local depth = 0
  if package.loaded['vim.lsp'] then
    local function consider(root)
      if type(root) ~= 'string' or root == '' then
        return
      end
      root = canonical(root):gsub('/+$', '')
      if file:sub(1, #root + 1) == root .. '/' then
        depth = math.max(depth, #root)
      end
    end
    for _, client in ipairs(vim.lsp.get_clients({ name = 'texlab' })) do
      consider((client.config or {}).root_dir)
      for _, folder in ipairs(client.workspace_folders or {}) do
        consider(vim.uri_to_fname(folder.uri))
      end
    end
  end
  return depth > 0 and { priority = 1, depth = depth, active = active } or nil
end

return M
