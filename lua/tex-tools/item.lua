local ts = require('tex-tools.treesitter')
local environment = require('tex-tools.environment')
local M = {}

local lists = { itemize = true, enumerate = true, description = true }
local definitions = {
  new_command_definition = true,
  old_command_definition = true,
  let_command_definition = true,
  environment_definition = true,
  paired_delimiter_definition = true,
}

local function blocked(node)
  local kind = node:type()
  return ts.comment_types[kind] or ts.literal_types[kind] or definitions[kind]
end

local function line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
end

local function text(bufnr, range)
  local sr, sc, er, ec = unpack(range)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
end

-- Item nodes omit separating whitespace and trailing comment siblings.
local function outer(node, bufnr)
  local sr, sc, er, ec = node:range()
  local suffix = line(bufnr, er):sub(ec + 1)
  local standalone = line(bufnr, sr):sub(1, sc):match('^[ \t]*$')
  if standalone and (suffix:match('^[ \t]*$') or suffix:match('^[ \t]*%%')) then
    return { sr, 0, er + 1, 0 }
  end
  return { sr, sc, er, ec + #suffix:match('^[ \t]*') }
end

local function position(row, col, prefix)
  for part, newline in prefix:gmatch('([^\n]*)(\n?)') do
    if newline == '' then
      col = col + #part
    else
      row, col = row + 1, 0
    end
  end
  return row, col
end

local function inner(node, bufnr)
  local header = ts.field(node, 'label') or ts.field(node, 'command')
  local _, _, sr, sc = header:range()
  local _, _, er, ec = node:range()
  local body = text(bufnr, { sr, sc, er, ec })
  local first, last = body:find('%S'), #body
  if not first then
    return nil
  end
  while body:sub(last, last):match('%s') do
    local slash = last - 1
    while body:sub(slash, slash) == '\\' do
      slash = slash - 1
    end
    -- Keep a trailing escaped space/newline as part of its command.
    if (last - slash - 1) % 2 == 1 then
      break
    end
    last = last - 1
  end
  local br, bc = position(sr, sc, body:sub(1, first - 1))
  er, ec = position(sr, sc, body:sub(1, last))
  return { br, bc, er, ec }
end

local function collect(node, items, root)
  if blocked(node) or (node ~= root and ts.environment(node)) then
    return
  end
  if node:type() == 'enum_item' then
    items[#items + 1] = node
    return
  end
  for child in node:iter_children() do
    if child:named() then
      collect(child, items, root)
    end
  end
end

local function validate(node, bufnr)
  local env, err = environment.from_node(node, bufnr)
  if not env then
    return nil, err
  end
  if not lists[env.name] then
    return nil, 'The nearest environment must be itemize, enumerate, or description'
  end
  if node:has_error() then
    return nil, 'List syntax is incomplete'
  end
  return env
end

function M.current(opts, count)
  opts = opts or {}
  local bufnr = ts.buffer(opts.bufnr)
  local node, err = ts.editable_node(opts)
  if not node then
    return nil, err
  end
  local nearest, ancestor = nil, node
  while ancestor do
    if blocked(ancestor) then
      return nil, 'No list text object in comments, literal content, or definitions'
    end
    if not nearest and ts.environment(ancestor) then
      nearest = ancestor
    end
    ancestor = ancestor:parent()
  end
  if not nearest then
    return nil, 'No surrounding LaTeX list'
  end
  local env, message = validate(nearest, bufnr)
  if not env then
    return nil, message
  end
  local pos = opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  -- Match ts.node's clamping without mutating the caller's query options.
  pos = { pos[1], math.min(pos[2], #line(bufnr, pos[1])) }
  local _, _, br, bc = env.begin_node:range()
  local er, ec = env.end_node:range()
  if not ts.contains({ br, bc, er, ec }, unpack(pos)) then
    return nil, 'Place the cursor inside the list body'
  end
  local items, item, preceding = {}, nil, nil
  collect(nearest, items, nearest)
  for _, candidate in ipairs(items) do
    local range = outer(candidate, bufnr)
    if ts.contains(range, unpack(pos)) then
      item = candidate
      break
    end
    local _, _, cr, cc = candidate:range()
    if cr < pos[1] or (cr == pos[1] and cc <= pos[2]) then
      preceding = candidate
    end
  end
  if not item and preceding then
    local _, _, cr, cc = preceding:range()
    -- Whitespace between items belongs to the preceding item, but unrelated
    -- headings and standalone comments must not extend an item's scope.
    if text(bufnr, { cr, cc, pos[1], pos[2] }):match('^%s*$') then
      item = preceding
    end
  end
  if not item then
    return nil, 'No current list item'
  end
  for _ = 2, count or 1 do
    local parent = item:parent()
    while parent and parent:type() ~= 'enum_item' do
      parent = parent:parent()
    end
    if not parent then
      return nil, 'Not enough enclosing LaTeX list items'
    end
    local scope = parent:parent()
    while scope and not ts.environment(scope) do
      scope = scope:parent()
    end
    local valid, problem
    if scope then
      valid, problem = validate(scope, bufnr)
    end
    if not valid then
      return nil, problem or 'No surrounding LaTeX list'
    end
    item = parent
  end
  return { outer = outer(item, bufnr), inner = inner(item, bufnr) }
end

return M
