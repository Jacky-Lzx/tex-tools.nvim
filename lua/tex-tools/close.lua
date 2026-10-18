local ts = require('tex-tools.treesitter')
local M = {}
local pairs = { ['{'] = '}', ['['] = ']', ['('] = ')', ['\\('] = '\\)', ['\\['] = '\\]' }
local right = {
  ['('] = ')',
  ['['] = ']',
  ['\\{'] = '\\}',
  ['\\langle'] = '\\rangle',
  ['|'] = '|',
  ['\\|'] = '\\|',
  ['\\lvert'] = '\\rvert',
  ['\\lVert'] = '\\rVert',
  ['.'] = '.',
}

function M.text()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local node, err = ts.editable_node({ pos = { row, math.max(0, col - 1) } })
  if not node then
    return nil, err
  end
  while node:parent() do
    local kind = node:type()
    if kind:match('_definition$') then
      return nil, 'Delimiter completion is unavailable in definitions'
    end
    node = node:parent()
  end
  local stack, captured = {}, nil
  local function event(value, range, opening, closing)
    if not captured and (range[1] > row or range[1] == row and range[2] >= col) then
      captured = vim.list_slice(stack)
    end
    local last = stack[#stack]
    if closing or (value == '$' or value == '$$') and last and last.expected == value then
      if last and last.expected == (closing or value) then
        last.closed = true
        stack[#stack] = nil
      else
        stack = {}
      end
    elseif opening or pairs[value] or value == '$' or value == '$$' then
      stack[#stack + 1] = { expected = opening or pairs[value] or value }
    elseif value == '}' or value == ']' or value == ')' or value == '\\)' or value == '\\]' then
      if last and last.expected == value then
        last.closed = true
        stack[#stack] = nil
      else
        stack = {}
      end
    end
  end
  local function visit(current)
    if current:missing() then
      return
    end
    local kind = current:type()
    if ts.comment_types[kind] or ts.literal_types[kind] or kind:match('_definition$') then
      return
    end
    if kind == 'begin' or kind == 'end' then
      local name = ts.field(ts.field(current, 'name'), 'text')
      if name and not current:has_error() then
        local value = '\\end{' .. ts.text(name, 0) .. '}'
        event(value, ts.range(current), kind == 'begin' and value or nil, kind == 'end' and value or nil)
      end
      return
    end
    if kind == 'math_delimiter' then
      local left, command = ts.field(current, 'left_delimiter'), ts.field(current, 'left_command')
      if left and command and ts.text(command, 0) == '\\left' then
        local value = right[ts.text(left, 0)]
        if value then
          local expected = '\\right' .. value
          event('', ts.range(command), expected)
          for child, field in current:iter_children() do
            if
              field ~= 'left_command'
              and field ~= 'left_delimiter'
              and field ~= 'right_command'
              and field ~= 'right_delimiter'
            then
              visit(child)
            end
          end
          local rc, rd = ts.field(current, 'right_command'), ts.field(current, 'right_delimiter')
          if rc and rd and not rc:missing() and not rd:missing() then
            event('', ts.range(rc), nil, expected)
          end
          return
        end
      end
    end
    if current:child_count() == 0 then
      local value = ts.text(current, 0)
      if
        pairs[value]
        or value == '}'
        or value == ']'
        or value == ')'
        or value == '$'
        or value == '$$'
        or value == '\\)'
        or value == '\\]'
      then
        event(value, ts.range(current))
      end
      return
    end
    for child in current:iter_children() do
      visit(child)
    end
  end
  visit(node)
  captured = captured or stack
  local last = captured[#captured]
  if not last then
    return nil, 'No open LaTeX delimiter at the cursor'
  end
  if last.closed then
    return nil, 'The nearest delimiter already has a closing marker'
  end
  return last.expected
end

function M.keys()
  local text = M.text()
  return text and vim.keycode(text) or ']]'
end

function M.insert()
  local text, err = M.text()
  if not text then
    return false, err
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  return require('tex-tools.edit').apply(
    vim.api.nvim_get_current_buf(),
    { { range = { pos[1] - 1, pos[2], pos[1] - 1, pos[2] }, text = text } }
  )
end
return M
