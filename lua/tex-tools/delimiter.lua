local ts = require('tex-tools.treesitter')
local edit = require('tex-tools.edit')
local M = {}

local shapes = {
  paren = { '(', ')' },
  bracket = { '[', ']' },
  brace = { '\\{', '\\}' },
  angle = { '\\langle', '\\rangle' },
  vert = { '\\lvert', '\\rvert' },
  Vert = { '\\lVert', '\\rVert' },
}
local aliases =
  { ['('] = 'paren', ['['] = 'bracket', ['{'] = 'brace', ['<'] = 'angle', ['|'] = 'vert', ['\\|'] = 'Vert' }
local opening, closing = {}, {}
for name, pair in pairs(shapes) do
  opening[pair[1]], closing[pair[2]] = name, name
end
-- Symmetric and invisible delimiters are unambiguous only with explicit sizing.
local scaled = { ['.'] = true, ['|'] = true, ['\\|'] = true, ['\\vert'] = true, ['\\Vert'] = true }
for _, pair in pairs(shapes) do
  scaled[pair[1]], scaled[pair[2]] = true, true
end
local size_commands = { ['\\left'] = true, ['\\right'] = true, ['\\middle'] = true }
for _, size in ipairs({ 'big', 'Big', 'bigg', 'Bigg' }) do
  for _, suffix in ipairs({ '', 'l', 'r', 'm' }) do
    size_commands['\\' .. size .. suffix] = true
  end
end

local function slice(bufnr, range)
  local sr, sc, er, ec = unpack(range)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
end

local function after(bufnr, row, col)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]:sub(col + 1, col + 1)
end

local function object(left, right, left_command, right_command)
  local sr, sc, ir, ic = unpack(left)
  local er, ec, lr, lc = unpack(right)
  if left_command then
    sr, sc = unpack(left_command)
    er, ec = unpack(right_command)
  end
  return {
    outer = { sr, sc, lr, lc },
    inner = { ir, ic, er, ec },
    opening = { sr, sc, ir, ic },
    closing = { er, ec, lr, lc },
    left = left,
    right = right,
    left_command = left_command,
    right_command = right_command,
    automatic = left_command ~= nil,
  }
end

local function marker(node, bufnr)
  local range, value = ts.range(node), ts.text(node, bufnr)
  -- The upstream grammar can include the following letters in a word field,
  -- e.g. the left delimiter of \left.x. Only the first glyph is a marker.
  if node:type() == 'word' and (value:sub(1, 1) == '.' or value:sub(1, 1) == '|') then
    range[3], range[4] = range[1], range[2] + 1
    value = value:sub(1, 1)
  end
  return range, value
end

local function automatic(node, bufnr)
  local left, right = ts.field(node, 'left_delimiter'), ts.field(node, 'right_delimiter')
  local lc, rc = ts.field(node, 'left_command'), ts.field(node, 'right_command')
  if node:has_error() or not left or not right or not lc or not rc or left:missing() or right:missing() then
    return nil, 'Math delimiter pair is incomplete'
  end
  if ts.text(lc, bufnr) ~= '\\left' or ts.text(rc, bufnr) ~= '\\right' then
    return nil, 'Only plain delimiters and matching \\left/\\right sizing are supported'
  end
  local left_range, left_value = marker(left, bufnr)
  local right_range, right_value = marker(right, bufnr)
  if not scaled[left_value] or not scaled[right_value] then
    return nil, 'Unsupported math delimiter spelling'
  end
  return object(left_range, right_range, ts.range(lc), ts.range(rc))
end

-- Inspect syntax tokens, never source text. Commands, groups, formulas, and
-- environments are atomic, so a pair cannot straddle their argument boundaries.
local function plain(scope, bufnr, pos)
  local stack, found, uncertain, sized, previous_command = {}, nil, false, false, nil
  local function visit(node)
    local kind, value = node:type()
    if ts.comment_types[kind] then
      return
    elseif kind == 'text' then
      for child in node:iter_children() do
        visit(child)
      end
      return
    elseif kind == '(' or kind == ')' or kind == '[' or kind == ']' then
      value = kind
    elseif kind == 'generic_command' then
      local command = ts.field(node, 'command')
      value = command and ts.text(command, bufnr)
      if opening[value] or closing[value] then
        node = command
      end
    end
    local name = value and opening[value]
    if name then
      stack[#stack + 1] = {
        node = node,
        name = name,
        uncertain = value == '[' and previous_command ~= nil,
        sized = size_commands[previous_command],
      }
    elseif value and closing[value] then
      local last = stack[#stack]
      if last and last.name == closing[value] then
        stack[#stack] = nil
        local pair = object(ts.range(last.node), ts.range(node))
        if ts.contains(pair.outer, pos[1], pos[2]) then
          uncertain = uncertain or last.uncertain
          sized = sized or last.sized or size_commands[previous_command]
          found = found or pair
        end
      else
        stack = {}
      end
    end
    previous_command = kind == 'generic_command' and not (opening[value] or closing[value]) and value or nil
  end
  local first, last = scope:child(0), scope:child(scope:child_count() - 1)
  for child, field in scope:iter_children() do
    local sized_marker = scope:type() == 'math_delimiter' and field
    local option_marker = scope:type():match('^brack_group') and (child == first or child == last)
    if not sized_marker and not option_marker then
      visit(child)
    end
  end
  if sized then
    return nil, 'A sized delimiter marker cannot be edited as a plain bracket'
  elseif uncertain then
    return nil, 'Brackets after a command may be an optional argument; its signature is unknown'
  end
  return found
end

local function overlaps(a, b)
  local function before(ar, ac, br, bc)
    return ar < br or (ar == br and ac < bc)
  end
  return before(a[1], a[2], b[3], b[4]) and before(b[1], b[2], a[3], a[4])
end

local function incomplete(node, range)
  if node:missing() then
    local row, col = node:range()
    return ts.contains(range, row, col)
  end
  if not overlaps(ts.range(node), range) then
    return false
  end
  if node:type() == 'ERROR' then
    return true
  end
  if node:has_error() then
    for child in node:iter_children() do
      if incomplete(child, range) then
        return true
      end
    end
  end
  return false
end

function M.current(opts)
  local node, err = ts.editable_node(opts)
  if not node then
    return nil, err
  end
  if not require('tex-tools.context').in_math(opts) then
    return nil, 'Math delimiter editing requires a math context'
  end
  local bufnr = ts.buffer(opts and opts.bufnr)
  local ancestor = node
  while ancestor do
    local kind = ancestor:type()
    if kind == 'begin' or kind == 'end' then
      return nil, 'Environment headers are not math delimiter contents'
    end
    if
      kind == 'inline_formula'
      or kind == 'displayed_equation'
      or require('tex-tools.context').is_math_environment(ancestor, bufnr)
    then
      break
    end
    ancestor = ancestor:parent()
  end
  local pos = opts and opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  while node do
    -- A sized pair owns its marker tokens; never reinterpret them as plain.
    local pair, message = plain(node, bufnr, pos)
    if message then
      return nil, message
    end
    if pair then
      if incomplete(node, pair.outer) then
        return nil, 'Math delimiter contents are incomplete'
      end
      pair.node = node
      return pair
    end
    if node:type() == 'math_delimiter' then
      local sized, reason = automatic(node, bufnr)
      if not sized or ts.contains(sized.outer, pos[1], pos[2]) then
        return sized, reason
      end
    end
    if
      node:type() == 'inline_formula'
      or node:type() == 'displayed_equation'
      or require('tex-tools.context').is_math_environment(node, bufnr)
    then
      break
    end
    node = node:parent()
  end
  return nil, 'No surrounding math delimiter pair'
end

local function editable()
  local pair, err = M.current()
  if not pair then
    return nil, err
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable then
    return nil, 'Buffer is not modifiable'
  end
  return pair, nil, bufnr
end

local function separated(bufnr, range, value)
  if value:match('\\[A-Za-z@]+$') and after(bufnr, range[3], range[4]):match('[A-Za-z@]') then
    return value .. ' '
  end
  return value
end

function M.change(name)
  local pair, err, bufnr = editable()
  if not pair then
    return false, err
  end
  local default = opening[slice(bufnr, pair.left)] or 'paren'
  return edit.with_name(
    bufnr,
    name,
    default,
    'Delimiter',
    function(value)
      return type(value) == 'string' and shapes[aliases[value] or value] ~= nil
    end,
    'Use paren, bracket, brace, angle, vert, or Vert',
    function(value)
      local target = shapes[aliases[value] or value]
      return edit.apply(bufnr, {
        { range = pair.left, text = separated(bufnr, pair.left, target[1]) },
        { range = pair.right, text = separated(bufnr, pair.right, target[2]) },
      })
    end
  )
end

local function has_middle(node, bufnr)
  if node:type() == 'math_delimiter' or ts.comment_types[node:type()] or ts.literal_types[node:type()] then
    return false
  end
  local command = ts.field(node, 'command')
  if command and ts.text(command, bufnr) == '\\middle' then
    return true
  end
  for child in node:iter_children() do
    if has_middle(child, bufnr) then
      return true
    end
  end
  return false
end

local function middle(pair, bufnr)
  if not pair.automatic then
    return false
  end
  local node = ts.node({ bufnr = bufnr, pos = { pair.outer[1], pair.outer[2] } })
  while node and node:type() ~= 'math_delimiter' do
    node = node:parent()
  end
  if node then
    for child in node:iter_children() do
      if has_middle(child, bufnr) then
        return true
      end
    end
  end
  return false
end

function M.unwrap()
  local pair, err, bufnr = editable()
  if not pair then
    return false, err
  end
  if middle(pair, bufnr) then
    return false, 'Removing \\left/\\right would leave an unmatched \\middle'
  end
  if pair.automatic then
    for _, marker in ipairs({ { pair.left_command, pair.left }, { pair.right_command, pair.right } }) do
      local gap = { marker[1][3], marker[1][4], marker[2][1], marker[2][2] }
      if not slice(bufnr, gap):match('^%s*$') then
        return false, 'Unwrap would discard comments inside a delimiter marker'
      end
    end
  end
  local body = slice(bufnr, pair.inner)
  local prefix = edit.control_word_before(bufnr, pair.outer[1], pair.outer[2])
  if
    (prefix and body:match('^[A-Za-z@]'))
    or (
      after(bufnr, pair.outer[3], pair.outer[4]):match('[A-Za-z@]')
      and (body == '' and prefix or edit.control_word_before(bufnr, pair.inner[3], pair.inner[4]))
    )
  then
    return false, 'Unwrap would merge a control word with adjacent text'
  end
  return edit.apply(bufnr, { { range = pair.outer, text = body } })
end

local function sizing_barrier(node, range, bufnr)
  if not overlaps(ts.range(node), range) or ts.comment_types[node:type()] then
    return false
  end
  local kind = node:type()
  if kind == 'delimiter' and ts.text(node, bufnr) == '&' then
    return true
  end
  local command = ts.field(node, 'command')
  if command then
    local value = ts.text(command, bufnr)
    return value == '\\\\' or value == '\\cr' or value == '\\intertext' or value == '\\shortintertext'
  end
  if kind == 'text' then
    for child in node:iter_children() do
      if sizing_barrier(child, range, bufnr) then
        return true
      end
    end
  end
  return false
end

function M.toggle_size()
  local pair, err, bufnr = editable()
  if not pair then
    return false, err
  end
  if pair.automatic then
    local left, right = slice(bufnr, pair.left), slice(bufnr, pair.right)
    if not opening[left] or opening[left] ~= closing[right] then
      return false, 'Disabling automatic sizing requires matching visible directional delimiters'
    end
    if middle(pair, bufnr) then
      return false, 'Removing \\left/\\right would leave an unmatched \\middle'
    end
    return edit.apply(bufnr, {
      { range = pair.left_command, text = '' },
      { range = pair.right_command, text = '' },
    })
  end
  for child in pair.node:iter_children() do
    if sizing_barrier(child, pair.inner, bufnr) then
      return false, 'Automatic sizing cannot cross an alignment cell or row boundary'
    end
  end
  return edit.apply(bufnr, {
    { range = pair.left, text = '\\left' .. slice(bufnr, pair.left) },
    { range = pair.right, text = '\\right' .. slice(bufnr, pair.right) },
  })
end

return M
