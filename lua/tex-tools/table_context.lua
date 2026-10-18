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

-- Keep only the most recently queried environment, as plain ranges. No syntax
-- nodes or buffers are retained, and edits invalidate the snapshot lazily.
local cached

local function index(node, env, bufnr)
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
      collect(child, tokens, bufnr)
    end
  end
  local index, column_spec = 1, nil
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
      column_spec = ts.range(arg)
      sr, sc, index = ar, ac, index + 1
    end
  end
  local excluded, boundaries = {}, {}
  for i = index, #tokens do
    local token = tokens[i]
    if token:type() == 'delimiter' then
      excluded[#excluded + 1] = ts.range(token)
      boundaries[#boundaries + 1] = { kind = 'cell', range = ts.range(token) }
    end
    local command = ts.field(token, 'command')
    if command and rules[ts.text(command, bufnr)] then
      excluded[#excluded + 1] = ts.range(token)
      boundaries[#boundaries + 1] = { kind = 'rule', range = ts.range(token) }
    end
    -- Flattened row-break command names have no command field of their own.
    local name = token:type() == 'command_name' and ts.text(token, bufnr)
    if name == '\\\\' or name == '\\tabularnewline' or name == '\\tabularnewline*' then
      local range = ts.range(token)
      local next_index = i + 1
      local star = tokens[next_index]
      if star and ts.text(star, bufnr) == '*' then
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
      excluded[#excluded + 1] = range
      boundaries[#boundaries + 1] = { kind = 'row', range = range }
    end
  end
  table.sort(excluded, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  local merged = {}
  for _, range in ipairs(excluded) do
    local previous = merged[#merged]
    if previous and (range[1] < previous[3] or (range[1] == previous[3] and range[2] <= previous[4])) then
      if range[3] > previous[3] or (range[3] == previous[3] and range[4] > previous[4]) then
        previous[3], previous[4] = range[3], range[4]
      end
    else
      merged[#merged + 1] = range
    end
  end
  return { body = { sr, sc, er, ec }, excluded = merged, boundaries = boundaries, column_spec = column_spec }
end

function M.structure(opts)
  local node, err = ts.editable_node(opts)
  local ancestor = node
  while ancestor do
    if ancestor:type():match('_definition$') then
      return nil, 'No table editing in definitions'
    end
    ancestor = ancestor:parent()
  end
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node or node:has_error() then
    return nil, err or 'No complete surrounding table or alignment'
  end
  local bufnr = ts.buffer(opts and opts.bufnr)
  local env, message = environment.from_node(node, bufnr)
  local result = env and index(node, env, bufnr)
  if not result then
    return nil, message or 'The nearest environment is not a supported table or alignment'
  end
  result.env = env
  return result
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
  local bufnr = query.bufnr
  local tick, id = vim.api.nvim_buf_get_changedtick(bufnr), node:id()
  if not cached or cached.bufnr ~= bufnr or cached.tick ~= tick or cached.id ~= id then
    local env = environment.from_node(node, bufnr)
    cached = { bufnr = bufnr, tick = tick, id = id, value = env and index(node, env, bufnr) or false }
  end
  local value = cached.value
  if not value or not ts.contains(value.body, unpack(query.pos)) then
    return false
  end
  local row, col = unpack(query.pos)
  local low, high = 1, #value.excluded
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local range = value.excluded[mid]
    if row < range[1] or (row == range[1] and col < range[2]) then
      high = mid - 1
    elseif ts.contains(range, row, col) then
      return false
    else
      low = mid + 1
    end
  end
  return true
end

return M
