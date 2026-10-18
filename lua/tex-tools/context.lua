local ts = require('tex-tools.treesitter')
local M = {}

local comments = { line_comment = true, block_comment = true, comment_environment = true, comment = true }
local literal = {
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
local math = { inline_formula = true, displayed_equation = true, math_environment = true }

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
      elseif ts.environment(node) then
        local begin = ts.field(node, 'begin')
        local name = ts.field(ts.field(begin, 'name'), 'text')
        if name then
          local value = ts.text(name, opts and opts.bufnr):gsub('%*$', '')
          for _, custom in ipairs(require('tex-tools.config').options.math_environments) do
            if value == custom:gsub('%*$', '') then
              result = true
              break
            end
          end
        end
      end
    end
    node = node:parent()
  end
  return result == true, err
end

return M
