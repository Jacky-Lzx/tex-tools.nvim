local M = {}
-- Keep snapshots in Lua: user mappings may contain Lua callbacks.
local installed = {}

local group = vim.api.nvim_create_augroup('TexToolsMappings', { clear = true })
vim.api.nvim_create_autocmd('BufWipeout', {
  group = group,
  callback = function(event)
    installed[event.buf] = nil
  end,
})

function M.clear(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    for _, map in ipairs(installed[bufnr] or {}) do
      local current = vim.fn.maparg(map.lhs, map.mode, false, true)
      -- Leave mappings changed by users or other plugins after attach alone.
      if vim.deep_equal(current, map.current) then
        vim.keymap.del(map.mode, map.lhs, { buffer = bufnr })
        if map.previous then
          vim.fn.mapset(map.mode, false, map.previous)
        end
      end
    end
  end)
  installed[bufnr] = nil
end

function M.set(bufnr, modes, lhs, rhs, opts, overwrite)
  vim.api.nvim_buf_call(bufnr, function()
    for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
      local previous = vim.fn.maparg(lhs, mode, false, true)
      if overwrite or vim.tbl_isempty(previous) then
        vim.keymap.set(mode, lhs, rhs, vim.tbl_extend('force', opts, { buffer = bufnr }))
        local current = vim.fn.maparg(lhs, mode, false, true)
        installed[bufnr] = installed[bufnr] or {}
        installed[bufnr][#installed[bufnr] + 1] = {
          mode = mode,
          lhs = current.lhs,
          current = current,
          -- Global mappings remain in place underneath the buffer-local one.
          previous = previous.buffer == 1 and previous or nil,
        }
      end
    end
  end)
end

return M
