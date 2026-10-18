local M = {}

M.comment_types = { line_comment = true, block_comment = true, comment_environment = true, comment = true }
M.literal_types = {
  verbatim_environment = true,
  listing_environment = true,
  minted_environment = true,
  asy_environment = true,
  asydef_environment = true,
  pycode_environment = true,
  luacode_environment = true,
  sageblock_environment = true,
  sagesilent_environment = true,
}

function M.buffer(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

local function current_trees(parser)
  return parser:is_valid(true) and parser:trees() or parser:parse()
end

---Return the current root without re-entering the parser for a valid LaTeX tree.
---Injected languages are deliberately irrelevant to structural TeX queries.
function M.root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, M.buffer(bufnr), 'latex')
  if not ok or not parser then
    return nil, 'LaTeX Tree-sitter parser unavailable; install the latex parser first'
  end
  local parsed, trees = pcall(current_trees, parser)
  if not parsed or not trees or not trees[1] then
    return nil, 'Could not parse this LaTeX buffer'
  end
  return trees[1]:root()
end

---Return a LaTeX node, deliberately ignoring injected languages.
---@param opts? {bufnr?: integer, pos?: integer[]}
---@return TSNode?, string?, integer?, integer[]?
function M.node(opts)
  opts = opts or {}
  local bufnr = M.buffer(opts.bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, 'Buffer is not loaded'
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
  local root, err = M.root(bufnr)
  if not root then
    return nil, err
  end
  return root:named_descendant_for_range(row, col, row, col), nil, bufnr, { row, col }
end

function M.field(node, name)
  return node and node:field(name)[1] or nil
end

function M.editable_node(opts)
  local node, err = M.node(opts)
  local ancestor = node
  while ancestor do
    local kind = ancestor:type()
    if M.comment_types[kind] or M.literal_types[kind] then
      return nil, 'No editable LaTeX structure in comments or literal content'
    end
    ancestor = ancestor:parent()
  end
  return node, err
end

function M.contains(range, row, col)
  local sr, sc, er, ec = unpack(range)
  return (row > sr or (row == sr and col >= sc)) and (row < er or (row == er and col < ec))
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
