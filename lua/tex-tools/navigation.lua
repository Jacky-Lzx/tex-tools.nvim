local ts = require('tex-tools.treesitter')
local environment = require('tex-tools.environment')
local context = require('tex-tools.context')
local M = {}

local sections = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}
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

local function complete(node)
  return node and not node:missing() and not node:has_error()
end

-- Section/item nodes include their bodies: validate the header fields only.
local function marker(node, section)
  local command = ts.field(node, 'command')
  if not complete(command) then
    return nil
  end
  if section and not complete(ts.field(node, 'text')) then
    return nil
  end
  local option = ts.field(node, section and 'toc' or 'label')
  if option and not complete(option) then
    return nil
  end
  local row, col = command:range()
  return { row, col }
end

local function structure_marker(node, kind)
  if ts.environment(node) and (kind == 'environment' or context.is_math_environment(node, 0)) then
    local env = environment.from_node(node, 0)
    if env and complete(env.begin_node) and complete(env.end_node) then
      local row, col = env.begin_node:range()
      return { row, col }
    end
  elseif kind == 'math' and (node:type() == 'inline_formula' or node:type() == 'displayed_equation') then
    local opening, closing = node:child(0), node:child(node:child_count() - 1)
    local pairs = { ['$'] = '$', ['$$'] = '$$', ['\\('] = '\\)', ['\\['] = '\\]' }
    if complete(node) and complete(opening) and complete(closing) and pairs[opening:type()] == closing:type() then
      local row, col = opening:range()
      return { row, col }
    end
  end
end

local function before(ar, ac, br, bc)
  return ar < br or (ar == br and ac < bc)
end

-- Visit in motion order. Binary-search the first relevant child so a nearby
-- target does not require walking distant siblings or their bodies.
local function search(node, kind, root, direction, row, col, accept)
  if blocked(node) or (kind == 'item' and node ~= root and ts.environment(node)) then
    return false
  end
  local sr, sc, er, ec = node:range()
  if (direction == 1 and not before(row, col, er, ec)) or (direction == -1 and not before(sr, sc, row, col)) then
    return false
  end
  local function visit_marker()
    local section = kind == 'section'
    local pos
    if (section and sections[node:type()]) or (kind == 'item' and node:type() == 'enum_item') then
      pos = marker(node, section)
    elseif kind == 'environment' or kind == 'math' then
      pos = structure_marker(node, kind)
    end
    if
      pos
      and ((direction == 1 and before(row, col, unpack(pos))) or (direction == -1 and before(pos[1], pos[2], row, col)))
    then
      return accept(pos)
    end
    return false
  end
  if direction == 1 and visit_marker() then
    return true
  end
  local size = node:named_child_count()
  local low, high = 0, size
  while low < high do
    local mid = math.floor((low + high) / 2)
    local cr, cc, lr, lc = node:named_child(mid):range()
    local skip = direction == 1 and not before(row, col, lr, lc) or direction == -1 and before(cr, cc, row, col)
    if skip then
      low = mid + 1
    else
      high = mid
    end
  end
  local first, last = low, size - 1
  if direction == -1 then
    first, last = low - 1, 0
  end
  for index = first, last, direction do
    if search(node:named_child(index), kind, root, direction, row, col, accept) then
      return true
    end
  end
  return direction == -1 and visit_marker() or false
end

local function scope(kind)
  local node, err = ts.node()
  if not node then
    return nil, err
  end
  if kind ~= 'item' then
    while node:parent() do
      node = node:parent()
    end
    return node
  end
  local nearest
  while node do
    if blocked(node) then
      return nil, 'No list navigation in comments, literal content, or definitions'
    end
    if not nearest and ts.environment(node) then
      nearest = node
    end
    node = node:parent()
  end
  if nearest then
    local env, message = environment.from_node(nearest, 0)
    if not env then
      return nil, message
    end
    if not lists[env.name] then
      return nil, 'The nearest environment must be itemize, enumerate, or description'
    end
    return nearest
  end
  return nil, 'No surrounding LaTeX list'
end

local function jump(kind, direction, count)
  count = count == nil and 1 or count
  if direction ~= 1 and direction ~= -1 then
    return false, 'Direction must be 1 (next) or -1 (previous)'
  end
  if type(count) ~= 'number' or count < 1 or count == math.huge or count % 1 ~= 0 then
    return false, 'Count must be a positive integer'
  end
  local root, err = scope(kind)
  if not root then
    return false, err
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local target
  search(root, kind, root, direction, row, col, function(pos)
    target = pos
    count = count - 1
    return count == 0
  end)
  if not target then
    return false, 'No ' .. (direction == 1 and 'next' or 'previous') .. ' ' .. kind
  end
  vim.cmd.normal({ "m'", bang = true })
  vim.api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
  vim.cmd.normal({ 'zv', bang = true })
  return true
end

function M.section(direction, count)
  return jump('section', direction, count)
end

function M.item(direction, count)
  return jump('item', direction, count)
end

function M.environment(direction, count)
  return jump('environment', direction, count)
end

function M.math(direction, count)
  return jump('math', direction, count)
end

return M
