local M = {}

function M.buffer(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

---Return a LaTeX node, deliberately ignoring injected languages.
---@param opts? {bufnr?: integer, pos?: integer[]}
---@return TSNode?, string?
function M.node(opts)
  opts = opts or {}
  local bufnr = M.buffer(opts.bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, 'Buffer is not loaded'
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'latex')
  if not ok or not parser then
    return nil, 'LaTeX Tree-sitter parser unavailable; install the latex parser first'
  end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then
    return nil, 'Could not parse this LaTeX buffer'
  end
  local pos = opts.pos
  if not pos then
    if bufnr ~= vim.api.nvim_get_current_buf() then
      return nil, 'Provide pos when inspecting a non-current buffer'
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  local row, col = pos[1], pos[2]
  if row < 0 or row >= vim.api.nvim_buf_line_count(bufnr) or col < 0 then
    return nil, 'Position is outside the buffer'
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  col = math.min(col, #line)
  return trees[1]:root():named_descendant_for_range(row, col, row, col)
end

function M.field(node, name)
  return node and node:field(name)[1] or nil
end

function M.text(node, bufnr)
  return vim.treesitter.get_node_text(node, M.buffer(bufnr))
end

function M.range(node)
  return { node:range() }
end

function M.environment(node)
  -- environment_definition also has begin/end fields, but is not an instance.
  return node:type():match('_environment$') ~= nil
end

return M
