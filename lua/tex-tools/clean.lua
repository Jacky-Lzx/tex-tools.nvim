local M = {}

local auxiliary = { '.aux', '.out', '.toc', '.lof', '.lot', '.fls', '.nav', '.snm', '.vrb', '.synctex.gz' }

function M.clean(full)
  vim.validate('full', full, 'boolean', true)
  if require('tex-tools.lsp').backend() == 'latex-lsp' then
    return require('tex-tools.lsp.latex').clean(full)
  end
  local lsp, manager = require('tex-tools.lsp'), require('tex-tools.build')
  local client, err = lsp.client()
  if not client then
    return false, err
  end
  local state = manager.state(client)
  if manager.active(client) or state.cleaning then
    return false, 'Wait for compilation or cleaning to finish before cleaning artifacts'
  end
  local resolver = require('tex-tools.project')
  local project
  project, err = resolver.resolve(client)
  if not project then
    return false, err
  end
  local backend = resolver.backend(project.build)
  if backend == 'latexmk' then
    -- texlab's cleanup operates on the given document, not its inferred parent.
    -- Ensure an explicitly resolved main document is known to the real server.
    if vim.lsp.get_client_by_id(client.id) == client then
      local bufnr = vim.fn.bufadd(project.main_file)
      vim.fn.bufload(bufnr)
      if not vim.lsp.buf_attach_client(bufnr, client.id) then
        return false, 'Could not attach the main document to texlab'
      end
    end
    state.cleaning = true
    local ok, result = lsp.execute(
      client,
      full and 'texlab.cleanArtifacts' or 'texlab.cleanAuxiliary',
      { { uri = vim.uri_from_fname(project.main_file) } },
      function(error)
        state.cleaning = nil
        vim.notify(
          error and (error.message or tostring(error)) or 'Build artifacts cleaned',
          error and vim.log.levels.ERROR or vim.log.levels.INFO,
          { title = 'tex-tools' }
        )
      end
    )
    if not ok then
      state.cleaning = nil
    end
    return ok, result
  end
  if backend ~= 'tectonic' then
    return false, 'Cleaning is supported only for latexmk and Tectonic; configured compiler: ' .. backend
  end
  local args = project.build.args or {}
  if
    (vim.tbl_contains(args, '-X') or vim.tbl_contains(args, '--unstable')) and not vim.tbl_contains(args, 'compile')
  then
    return false, 'Tectonic cleanup requires the compile command; project build/watch outputs are ambiguous'
  end
  if full and not project.pdf_name:match('%.pdf$') then
    return false, 'Full cleanup requires a PDF filename ending in .pdf'
  end
  local paths = {}
  for _, suffix in ipairs(auxiliary) do
    paths[#paths + 1] = vim.fs.joinpath(project.aux_dir, project.stem .. suffix)
  end
  paths[#paths + 1] = vim.fs.joinpath(project.log_dir, project.stem .. '.log')
  if full then
    paths[#paths + 1] = vim.fs.joinpath(project.pdf_dir, project.pdf_name)
  end
  -- Inspect every exact path before deleting anything. Never recurse into a
  -- directory, and unlink a leaf symlink itself rather than following its target.
  local candidates = {}
  for _, path in ipairs(paths) do
    local stat, stat_err, code = vim.uv.fs_lstat(path)
    if stat then
      if stat.type ~= 'file' and stat.type ~= 'link' then
        return false, 'Refusing to remove a non-file artifact: ' .. path
      end
      candidates[#candidates + 1] = path
    elseif code ~= 'ENOENT' then
      return false, 'Could not inspect artifact ' .. path .. ': ' .. tostring(stat_err)
    end
  end
  local removed = 0
  for _, path in ipairs(candidates) do
    local ok, unlink_err = vim.uv.fs_unlink(path)
    if not ok then
      return false, ('Removed %d artifacts; could not remove %s: %s'):format(removed, path, unlink_err)
    end
    removed = removed + 1
  end
  return true, removed
end

return M
