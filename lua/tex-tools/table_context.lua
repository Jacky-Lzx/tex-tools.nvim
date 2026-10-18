local ts = require('tex-tools.treesitter')
local environment = require('tex-tools.environment')
local M = {}

-- Number of mandatory header groups after the parser-owned begin marker.
local headers = {
  tabular = 1,
  ['tabular*'] = 2,
  tabularx = 2,
  array = 1,
  matrix = 0,
  pmatrix = 0,
  bmatrix = 0,
  Bmatrix = 0,
  vmatrix = 0,
  Vmatrix = 0,
  smallmatrix = 0,
  cases = 0,
  aligned = 0,
  alignedat = 1,
  align = 0,
  alignat = 1,
  flalign = 0,
  split = 0,
}
local rules = {
  ['\\hline'] = true,
  ['\\vline'] = true,
  ['\\cline'] = true,
  ['\\toprule'] = true,
  ['\\midrule'] = true,
  ['\\bottomrule'] = true,
  ['\\cmidrule'] = true,
  ['\\addlinespace'] = true,
}

local function rowbreak(node, bufnr)
  local command = node:type() == 'generic_command' and ts.field(node, 'command')
  local name = command and ts.text(command, bufnr)
  return name == '\\\\' or name == '\\tabularnewline' or name == '\\tabularnewline*'
end

-- Flatten only parser text wrappers. Groups, commands, formulas, and nested
-- environments are atomic: their & and row breaks cannot split outer cells.
local function collect(node, tokens, bufnr)
  if ts.comment_types[node:type()] then
    return
  elseif node:type() == 'text' then
    for child in node:iter_children() do
      collect(child, tokens, bufnr)
    end
  elseif rowbreak(node, bufnr) then
    tokens[#tokens + 1] = ts.field(node, 'command')
    -- The generic grammar can attach a following row's braced cell to \\.
    for _, arg in ipairs(node:field('arg')) do
      tokens[#tokens + 1] = arg
    end
  else
    tokens[#tokens + 1] = node
  end
end

-- Some environment options are brack_group nodes; math environment options
-- are sibling [ / ] tokens. Inspect those tokens without scanning source text.
local function option(tokens, index)
  local first = tokens[index]
  if not first then
    return index
  elseif first:type():match('^brack_group') then
    return index + 1, ts.range(first)
  elseif first:type() ~= '[' then
    return index
  end
  local depth = 0
  for i = index, #tokens do
    if tokens[i]:type() == '[' then
      depth = depth + 1
    elseif tokens[i]:type() == ']' then
      depth = depth - 1
      if depth == 0 then
        local sr, sc = first:range()
        local _, _, er, ec = tokens[i]:range()
        return i + 1, { sr, sc, er, ec }
      end
    end
  end
  return nil
end

function M.in_cell(opts)
  local query, err = require('tex-tools.context').query(opts)
  if not query then
    return false, err
  end
  local node = query.node
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node or node:has_error() then
    return false
  end
  local env = environment.from_node(node, query.bufnr)
  if not env then
    return false
  end
  -- Normalize starred variants, except tabular* which has its own width arg.
  local required = headers[env.name] or headers[env.name:gsub('%*$', '')]
  if required == nil then
    return false
  end
  local _, _, sr, sc = env.begin_node:range()
  local er, ec = env.end_node:range()
  local tokens = {}
  for child in node:iter_children() do
    if child ~= env.begin_node and child ~= env.end_node then
      collect(child, tokens, query.bufnr)
    end
  end
  local index = 1
  for _ = 1, math.max(1, required) do
    local range
    index, range = option(tokens, index)
    if not index then
      return false
    end
    if range then
      sr, sc = range[3], range[4]
    end
    if required > 0 then
      local arg = tokens[index]
      if not arg or not require('tex-tools.structure').group_node(arg) then
        return false
      end
      local _, _, ar, ac = arg:range()
      sr, sc, index = ar, ac, index + 1
    end
  end
  if not ts.contains({ sr, sc, er, ec }, unpack(query.pos)) then
    return false
  end
  for i = index, #tokens do
    local token = tokens[i]
    if token:type() == 'delimiter' and ts.contains(ts.range(token), unpack(query.pos)) then
      return false
    end
    local command = ts.field(token, 'command')
    if command and rules[ts.text(command, query.bufnr)] and ts.contains(ts.range(token), unpack(query.pos)) then
      return false
    end
    -- Flattened row-break command names have no command field of their own.
    local name = token:type() == 'command_name' and ts.text(token, query.bufnr)
    if name == '\\\\' or name == '\\tabularnewline' or name == '\\tabularnewline*' then
      local range = ts.range(token)
      local next_index = i + 1
      local star = tokens[next_index]
      if star and ts.text(star, query.bufnr) == '*' then
        local tr, tc = star:range()
        if tr == range[3] and tc == range[4] then
          range[3], range[4] = select(3, star:range())
          next_index = next_index + 1
        end
      end
      local after_option, spacing = option(tokens, next_index)
      if not after_option then
        return false
      end
      if spacing then
        range[3], range[4] = spacing[3], spacing[4]
      end
      if ts.contains(range, unpack(query.pos)) then
        return false
      end
    end
  end
  return true
end

return M
