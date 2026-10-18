local ts = require('tex-tools.treesitter')
local edit = require('tex-tools.edit')
local M = {}
local function text(range)
  return table.concat(vim.api.nvim_buf_get_text(0, range[1], range[2], range[3], range[4], {}), '\n')
end

function M.toggle()
  if not require('tex-tools.context').in_math() then
    return false, 'Fraction editing requires math mode'
  end
  local node, err = ts.editable_node()
  if not node then
    return false, err
  end
  local ancestor = node
  while ancestor do
    local command = ts.field(ancestor, 'command')
    local name = command and ts.text(command, 0)
    if name == '\\frac' or name == '\\dfrac' or name == '\\tfrac' then
      local object, message = require('tex-tools.structure').command_node(ancestor, 0)
      if message or #object.arguments ~= 2 or object.other_fields then
        return false, message or 'Fraction requires exactly two braced arguments'
      end
      local args = object.arguments
      for _, argument in ipairs(args) do
        if not argument.node:type():match('^curly_group') then
          return false, 'Fraction arguments must be braced'
        end
      end
      local gaps = {
        { object.inner[3], object.inner[4], args[1].outer[1], args[1].outer[2] },
        { args[1].outer[3], args[1].outer[4], args[2].outer[1], args[2].outer[2] },
      }
      for _, gap in ipairs(gaps) do
        if text(gap):match('%S') then
          return false, 'Conversion would discard fraction comments or options'
        end
      end
      local values = {}
      for _, argument in ipairs(args) do
        local body = text(argument.inner)
        if body == '' or body:find('\n', 1, true) or body:find('%%') then
          return false, 'Slash fractions require nonempty single-line operands without comments'
        end
        values[#values + 1] = body:match('^[%w]+$') and body or ('{' .. body .. '}')
      end
      return edit.apply(
        vim.api.nvim_get_current_buf(),
        { { range = object.outer, text = table.concat(values, '/') } },
        { module = 'fraction', method = 'toggle' }
      )
    end
    ancestor = ancestor:parent()
  end
  -- Work within one syntax scope. Commands/groups are atoms; operators split
  -- operands. Superscripts/subscripts remain attached to the preceding atom.
  local scope = node
  while
    scope:type() == 'word'
    or scope:type() == 'operator'
    or scope:type() == 'letter'
    or scope:type() == 'superscript'
    or scope:type() == 'subscript'
  do
    scope = scope:parent()
  end
  if scope:type() == 'text' then
    scope = scope:parent()
  end
  local tokens = {}
  local function visit(child)
    if child:type() == 'text' then
      for item in child:iter_children() do
        visit(item)
      end
    elseif child:named() then
      tokens[#tokens + 1] = child
    end
  end
  for child in scope:iter_children() do
    visit(child)
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local candidates = {}
  for index, token in ipairs(tokens) do
    if token:type() == 'operator' and ts.text(token, 0) == '/' then
      local left, right = index - 1, index + 1
      while left > 1 and (tokens[left]:type() == 'superscript' or tokens[left]:type() == 'subscript') do
        left = left - 1
      end
      while
        right < #tokens and (tokens[right + 1]:type() == 'superscript' or tokens[right + 1]:type() == 'subscript')
      do
        right = right + 1
      end
      local a, b = tokens[left], tokens[right]
      local function operand(n)
        return n
          and (n:type() == 'word' or n:type() == 'generic_command' or n:type() == 'curly_group' or n:type() == 'superscript' or n:type() == 'subscript')
          and not n:has_error()
      end
      if operand(a) and operand(b) then
        local ar, ac = a:range()
        local _, _, br, bc = b:range()
        local range = { ar, ac, br, bc }
        if ts.contains(range, cursor[1] - 1, cursor[2]) then
          candidates[#candidates + 1] = { left = left, slash = index, right = right, range = range }
        end
      end
    end
  end
  if #candidates ~= 1 then
    return false, 'Place the cursor on an unambiguous a/b expression; brace compound operands'
  end
  local candidate = candidates[1]
  if
    (tokens[candidate.left - 1] and ts.text(tokens[candidate.left - 1], 0) == '/')
    or (tokens[candidate.right + 1] and ts.text(tokens[candidate.right + 1], 0) == '/')
  then
    return false, 'Chained slash fractions are ambiguous; group the intended operands'
  end
  local slash = ts.range(tokens[candidate.slash])
  local numerator = text({ candidate.range[1], candidate.range[2], slash[1], slash[2] }):match('^%s*(.-)%s*$')
  local denominator = text({ slash[3], slash[4], candidate.range[3], candidate.range[4] }):match('^%s*(.-)%s*$')
  if numerator:find('\n', 1, true) or denominator:find('\n', 1, true) then
    return false, 'Use a single-line slash expression'
  end
  local function argument(value)
    if value:sub(1, 1) == '{' and value:sub(-1) == '}' then
      return value
    end
    return '{' .. value .. '}'
  end
  return edit.apply(
    vim.api.nvim_get_current_buf(),
    { { range = candidate.range, text = '\\frac' .. argument(numerator) .. argument(denominator) } },
    { module = 'fraction', method = 'toggle' }
  )
end
return M
