local M = {}
local last, arming, running
local operator = "v:lua.require'tex-tools.repeat'.operator"

local function tex_buffer()
  return vim.bo.filetype == 'tex' or vim.bo.filetype == 'plaintex'
end

---Register only a completed edit; saved actions contain values, never ranges/nodes.
function M.record(bufnr, action)
  if running or bufnr ~= vim.api.nvim_get_current_buf() or vim.fn.mode() ~= 'n' or not tex_buffer() then
    return
  end
  local previous, previous_operator = last, vim.go.operatorfunc
  local view = vim.fn.winsaveview()
  local first, final = vim.fn.getpos("'["), vim.fn.getpos("']")
  last, arming = vim.deepcopy(action), true
  vim.go.operatorfunc = operator
  -- g@l works at end-of-line and in an empty buffer. The first call does no
  -- work: the real edit already succeeded. Native dot later calls operator().
  local ok = pcall(vim.cmd.normal, { 'g@l', bang = true })
  arming = false
  vim.fn.setpos("'[", first)
  vim.fn.setpos("']", final)
  vim.fn.winrestview(view)
  if not ok then
    last, vim.go.operatorfunc = previous, previous_operator
  end
end

---Native g@ callback. Counts repeat the semantic operation at the same cursor.
function M.operator()
  if arming or running or not last then
    return
  end
  if not tex_buffer() then
    vim.notify('Structural repeat requires a tex or plaintex buffer', vim.log.levels.WARN, { title = 'tex-tools' })
    return
  end
  running = true
  local action = last
  local ok, err
  local completed, failure = pcall(function()
    for _ = 1, vim.v.count1 do
      local node
      node, err = require('tex-tools.treesitter').editable_node()
      if not node then
        ok = false
        break
      end
      ok, err = require('tex-tools.' .. action.module)[action.method](unpack(action.args or {}))
      if not ok then
        break
      end
    end
  end)
  running = false
  if not completed or not ok then
    vim.notify(completed and err or tostring(failure), vim.log.levels.WARN, { title = 'tex-tools' })
  end
end

return M
