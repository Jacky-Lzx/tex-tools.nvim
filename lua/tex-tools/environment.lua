local ts = require('tex-tools.treesitter')
local M = {}

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return table?, string?
function M.current(opts)
  opts = opts or {}
  local bufnr = ts.buffer(opts.bufnr)
  local node, err = ts.node(opts)
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node then
    return nil, err or 'No surrounding LaTeX environment'
  end
  local begin_node, end_node = ts.field(node, 'begin'), ts.field(node, 'end')
  if not begin_node or not end_node or end_node:missing() then
    return nil, 'Environment is incomplete'
  end
  local begin_name = ts.field(ts.field(begin_node, 'name'), 'text')
  local end_name = ts.field(ts.field(end_node, 'name'), 'text')
  if not begin_name or not end_name or begin_name:missing() or end_name:missing() then
    return nil, 'Environment name is incomplete'
  end
  local name = ts.text(begin_name, bufnr)
  if name == '' or name ~= ts.text(end_name, bufnr) then
    return nil, 'Environment begin/end names do not match'
  end
  return {
    bufnr = bufnr,
    node = node,
    name = name,
    begin_node = begin_node,
    end_node = end_node,
    begin_name = begin_name,
    end_name = end_name,
  }
end

local function rename(env, name)
  if not name:match('^[%a@][%w@*_-]*$') then
    return false, 'Use a literal environment name, e.g. equation*'
  end
  if not vim.bo[env.bufnr].modifiable then
    return false, 'Buffer is not modifiable'
  end
  -- LSP TextEdit is used only as an atomic editing utility. Tree-sitter ranges
  -- use byte columns, so the encoding must be UTF-8, regardless of texlab.
  local edits = {}
  for _, node in ipairs({ env.begin_name, env.end_name }) do
    local sr, sc, er, ec = node:range()
    edits[#edits + 1] = {
      range = { start = { line = sr, character = sc }, ['end'] = { line = er, character = ec } },
      newText = name,
    }
  end
  vim.lsp.util.apply_text_edits(edits, env.bufnr, 'utf-8')
  return true
end

---@param name? string Prompt with vim.ui.input when omitted.
---@return boolean, string?
function M.rename(name)
  local env, err = M.current()
  if not env then
    return false, err
  end
  if name ~= nil then
    return rename(env, name)
  end
  local tick = vim.api.nvim_buf_get_changedtick(env.bufnr)
  vim.ui.input({ prompt = 'Environment: ', default = env.name }, function(value)
    if not value or value == '' then
      return
    end
    if not vim.api.nvim_buf_is_valid(env.bufnr) or vim.api.nvim_buf_get_changedtick(env.bufnr) ~= tick then
      vim.notify('Buffer changed; run environment rename again', vim.log.levels.WARN, { title = 'tex-tools' })
      return
    end
    local ok, message = rename(env, value)
    if not ok then
      vim.notify(message, vim.log.levels.WARN, { title = 'tex-tools' })
    end
  end)
  return true
end

function M.toggle_star()
  local env, err = M.current()
  if not env then
    return false, err
  end
  local name = env.name:sub(-1) == '*' and env.name:sub(1, -2) or (env.name .. '*')
  return rename(env, name)
end

---Jump from the end marker to the begin marker, or from the body/begin to end.
function M.jump()
  local env, err = M.current()
  if not env then
    return false, err
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local er, ec = env.end_node:range()
  local target = (row > er or (row == er and col >= ec)) and env.begin_node or env.end_node
  local tr, tc = target:range()
  vim.cmd.normal({ "m'", bang = true })
  vim.api.nvim_win_set_cursor(0, { tr + 1, tc })
  return true
end

return M
