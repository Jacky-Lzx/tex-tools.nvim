local ts = require('tex-tools.treesitter')
local M = {}

local comments = ts.comment_types
local literal = ts.literal_types
local math_nodes = { inline_formula = true, displayed_equation = true, math_environment = true }

function M.is_math_environment(node, bufnr)
  if node:type() == 'math_environment' then
    return true
  end
  if ts.environment(node) then
    local name = ts.field(ts.field(ts.field(node, 'begin'), 'name'), 'text')
    if name then
      local value = ts.text(name, bufnr):gsub('%*$', '')
      for _, custom in ipairs(require('tex-tools.config').options.math_environments) do
        if value == custom:gsub('%*$', '') then
          return true
        end
      end
    end
  end
  return false
end

-- Cache plain results for one position, never TSNodes. Every call still asks
-- Tree-sitter for a current node, so parser failures and reparses stay visible.
local cached

local function inspect(opts)
  local node, err = ts.node(opts)
  if not node then
    return nil, err
  end
  local bufnr = ts.buffer(opts and opts.bufnr)
  local pos = opts and opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1]
  pos = { pos[1], math.min(pos[2], #line) }
  local tick, id = vim.api.nvim_buf_get_changedtick(bufnr), node:id()
  local config = require('tex-tools.config').options
  if
    not cached
    or cached.bufnr ~= bufnr
    or cached.tick ~= tick
    or cached.id ~= id
    or cached.row ~= pos[1]
    or cached.col ~= pos[2]
    or cached.config ~= config
  then
    local ancestor, math, comment, literal_content, blocked = node, nil, false, false, false
    while ancestor do
      local kind = ancestor:type()
      comment = comment or comments[kind] == true
      literal_content = literal_content or literal[kind] == true
      blocked = blocked or comments[kind] == true or literal[kind] == true
      if math == nil then
        if kind == 'text_mode' then
          math = false
        elseif math_nodes[kind] or M.is_math_environment(ancestor, bufnr) then
          math = true
        end
      end
      ancestor = ancestor:parent()
    end
    cached = {
      bufnr = bufnr,
      tick = tick,
      id = id,
      row = pos[1],
      col = pos[2],
      config = config,
      math = math == true and not blocked,
      comment = comment and not literal_content,
      blocked = blocked,
      results = {},
    }
  end
  return { node = node, bufnr = bufnr, pos = pos, snapshot = cached }
end

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return boolean, string?
function M.in_comment(opts)
  local query, err = inspect(opts)
  return query and query.snapshot.comment or false, err
end

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return boolean, string?
function M.in_math(opts)
  local query, err = inspect(opts)
  return query and query.snapshot.math or false, err
end

-- Shared by read-only context queries. Keep the caller's options untouched.
function M.query(opts)
  local query, err = inspect(opts)
  if not query or query.snapshot.blocked then
    return nil, err
  end
  return query
end

local function payload(node, pos)
  if not node or node:missing() or node:has_error() then
    return false
  end
  if node:type() == 'curly_group' then
    local object = require('tex-tools.structure').group_node(node)
    if not object then
      return false
    end
    local sr, sc, er, ec = unpack(object.inner)
    -- Include the insertion position immediately before the closing brace,
    -- including empty groups, for snippet conditions in Insert mode.
    return (pos[1] > sr or (pos[1] == sr and pos[2] >= sc)) and (pos[1] < er or (pos[1] == er and pos[2] <= ec))
  end
  return ts.contains(ts.range(node), unpack(pos))
end

local function math_payload(kind, query)
  if not query.snapshot.math then
    return false
  end
  local node = query.node
  while node do
    if math_nodes[node:type()] or M.is_math_environment(node, query.bufnr) then
      break
    end
    if (kind == 'subscript' or kind == 'superscript') and node:type() == kind then
      if payload(ts.field(node, kind), query.pos) then
        return true
      end
    elseif (kind == 'numerator' or kind == 'denominator') and node:type() == 'generic_command' then
      local command = ts.field(node, 'command')
      local name = command and ts.text(command, query.bufnr)
      if name == '\\frac' or name == '\\dfrac' or name == '\\tfrac' then
        local args = node:field('arg')
        if
          #args < 2
          or not require('tex-tools.structure').group_node(args[1])
          or not require('tex-tools.structure').group_node(args[2])
        then
          return false
        end
        return payload(args[kind == 'numerator' and 1 or 2], query.pos)
      end
    end
    node = node:parent()
  end
  return false
end

local function role(kind, opts)
  local query, err = M.query(opts)
  if not query then
    return false, err
  end
  local results = query.snapshot.results
  if results[kind] == nil then
    results[kind] = math_payload(kind, query)
  end
  return results[kind]
end

function M.in_subscript(opts)
  return role('subscript', opts)
end

function M.in_superscript(opts)
  return role('superscript', opts)
end

function M.in_numerator(opts)
  return role('numerator', opts)
end

function M.in_denominator(opts)
  return role('denominator', opts)
end

function M.in_table_cell(opts)
  return require('tex-tools.table_context').in_cell(opts)
end

return M
