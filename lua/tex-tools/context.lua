local ts = require('tex-tools.treesitter')
local M = {}

local comments = ts.comment_types
local literal = ts.literal_types
local math = { inline_formula = true, displayed_equation = true, math_environment = true }

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

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return boolean, string?
function M.in_comment(opts)
  local node, err = ts.node(opts)
  local found = false
  while node do
    local kind = node:type()
    -- The grammar uses a "comment" child to hold verbatim content.
    if literal[kind] then
      return false
    end
    found = found or comments[kind] == true
    node = node:parent()
  end
  return found, err
end

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return boolean, string?
function M.in_math(opts)
  local node, err = ts.node(opts)
  local result
  while node do
    local kind = node:type()
    if comments[kind] or literal[kind] then
      return false
    end
    if result == nil then
      if kind == 'text_mode' then
        result = false
      elseif math[kind] then
        result = true
      elseif M.is_math_environment(node, opts and opts.bufnr) then
        result = true
      end
    end
    node = node:parent()
  end
  return result == true, err
end

return M
