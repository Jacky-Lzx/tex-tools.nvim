local ts = require('tex-tools.treesitter')
local structure = require('tex-tools.structure')
local edit = require('tex-tools.edit')
local M = {}

local function contents(bufnr, range)
  local sr, sc, er, ec = unpack(range)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
end

local function before(ar, ac, br, bc)
  return ar < br or (ar == br and ac < bc)
end

local function contains(outer, inner)
  return not before(inner[1], inner[2], outer[1], outer[2]) and not before(outer[3], outer[4], inner[3], inner[4])
end

local function overlaps(a, b)
  return before(a[1], a[2], b[3], b[4]) and before(b[1], b[2], a[3], a[4])
end

local function after(bufnr, row, col)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]:sub(col + 1, col + 1)
end

local function current()
  local object, err = structure.command()
  if not object then
    return nil, err
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not edit.command_name(contents(bufnr, object.inner)) then
    return nil, 'Only control-word commands (ASCII letters or @, optionally starred) can be edited'
  end
  if not vim.bo[bufnr].modifiable then
    return nil, 'Buffer is not modifiable'
  end
  return object, nil, bufnr
end

function M.rename(name)
  local object, err, bufnr = current()
  if not object then
    return false, err
  end
  local range = object.inner
  return edit.with_command_name(bufnr, name, contents(bufnr, range), function(value)
    if value:match('[A-Za-z@]$') and after(bufnr, range[3], range[4]):match('[A-Za-z@]') then
      return false, 'Renaming would merge the command name with following text'
    end
    return edit.apply(bufnr, { { range = range, text = value } })
  end)
end

function M.unwrap()
  local object, err, bufnr = current()
  if not object then
    return false, err
  end
  local argument = object.arguments[1]
  if #object.arguments ~= 1 or object.other_fields or not argument.node:type():match('^curly_group') then
    return false, 'Unwrap requires exactly one braced argument and no options or other arguments'
  end
  local gap = { object.inner[3], object.inner[4], argument.outer[1], argument.outer[2] }
  if not contents(bufnr, gap):match('^%s*$') then
    return false, 'Unwrap would discard text or comments before the argument'
  end
  local body = contents(bufnr, argument.inner)
  local sr, sc, er, ec = unpack(object.outer)
  local prefix_word = edit.control_word_before(bufnr, sr, sc)
  local tail = after(bufnr, er, ec)
  if
    (prefix_word and body:match('^[A-Za-z@]'))
    or (
      tail:match('[A-Za-z@]')
      and (body == '' and prefix_word or edit.control_word_before(bufnr, argument.inner[3], argument.inner[4]))
    )
  then
    return false, 'Unwrap would merge a control word with adjacent text'
  end
  return edit.apply(bufnr, { { range = object.outer, text = body } })
end

local function range_for(bufnr, opts)
  opts = opts == nil and {} or opts
  if type(opts) ~= 'table' then
    return nil, 'Options must be a table'
  end
  local range = opts.range
  if range == nil then
    local first = opts.line1 == nil and vim.api.nvim_win_get_cursor(0)[1] or opts.line1
    local last = opts.line2 == nil and first or opts.line2
    if
      type(first) ~= 'number'
      or type(last) ~= 'number'
      or first % 1 ~= 0
      or last % 1 ~= 0
      or first < 1
      or last < first
      or last > vim.api.nvim_buf_line_count(bufnr)
    then
      return nil, 'Invalid line range'
    end
    range = { first - 1, 0, last - 1, #vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] }
  elseif opts.line1 ~= nil or opts.line2 ~= nil then
    return nil, 'Use either range or line1/line2'
  end
  if type(range) ~= 'table' or #range ~= 4 then
    return nil, 'Range must contain four zero-based byte coordinates'
  end
  for i = 1, 4 do
    local value = range[i]
    if type(value) ~= 'number' or value < 0 or value == math.huge or value % 1 ~= 0 then
      return nil, 'Invalid range coordinate ' .. i
    end
  end
  local sr, sc, er, ec = unpack(range)
  if er >= vim.api.nvim_buf_line_count(bufnr) or not before(sr, sc, er, ec) then
    return nil, 'Select a nonempty range inside the buffer'
  end
  for _, pos in ipairs({ { sr, sc }, { er, ec } }) do
    local line = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1]
    local byte = line and line:byte(pos[2] + 1)
    if not line or pos[2] > #line or (byte and byte >= 128 and byte < 192) then
      return nil, 'Range boundaries must fall between UTF-8 characters'
    end
  end
  return vim.deepcopy(range)
end

-- A selection may contain a whole structure, or stay inside one of its bodies.
-- Crossing an argument, command header, formula, or environment boundary is unsafe.
local function compatible(range, outer, inners)
  if not overlaps(range, outer) or contains(range, outer) then
    return true
  end
  for _, inner in ipairs(inners) do
    if contains(inner, range) then
      return true
    end
  end
  return false
end

local function check_node(node, bufnr, range)
  if not overlaps(range, ts.range(node)) then
    return true
  end
  local kind = node:type()
  if ts.comment_types[kind] or ts.literal_types[kind] or kind == 'ERROR' or node:missing() then
    return false, 'Select complete LaTeX text outside comments and literal content'
  end
  local group, group_err = structure.group_node(node)
  if group_err then
    return false, group_err
  end
  if group and not compatible(range, group.outer, { group.inner }) then
    return false, 'Selection crosses an argument delimiter'
  end
  local object, object_err = structure.command_node(node, bufnr)
  if object and overlaps(range, object.outer) then
    if object_err then
      return false, object_err
    end
    local inners = {}
    for _, argument in ipairs(object.arguments) do
      inners[#inners + 1] = argument.inner
    end
    if not compatible(range, object.outer, inners) then
      return false, 'Select a complete command or text inside one argument'
    end
  end
  if kind == 'command_name' or kind:match('_command_name$') then
    if not contains(range, ts.range(node)) then
      return false, 'Selection cuts through a command name'
    end
  elseif kind == 'inline_formula' or kind == 'displayed_equation' then
    local first, last = node:child(0), node:child(node:child_count() - 1)
    if node:has_error() or not first or not last then
      return false, 'Formula is incomplete'
    end
    local pairs = { ['$'] = '$', ['$$'] = '$$', ['\\('] = '\\)', ['\\['] = '\\]' }
    if pairs[first:type()] ~= last:type() then
      return false, 'Math delimiters do not match'
    end
    local _, _, sr, sc = first:range()
    local er, ec = last:range()
    if not compatible(range, ts.range(node), { { sr, sc, er, ec } }) then
      return false, 'Selection crosses a math delimiter'
    end
  elseif kind == 'math_delimiter' then
    local left, right = ts.field(node, 'left_delimiter'), ts.field(node, 'right_command')
    if node:has_error() or not left or not right then
      return false, 'Math delimiters are incomplete'
    end
    local _, _, sr, sc = left:range()
    local er, ec = right:range()
    if not compatible(range, ts.range(node), { { sr, sc, er, ec } }) then
      return false, 'Selection crosses a math delimiter'
    end
  elseif ts.environment(node) then
    local env, err = require('tex-tools.environment').from_node(node, bufnr)
    if not env then
      return false, err
    end
    local _, _, sr, sc = env.begin_node:range()
    local er, ec = env.end_node:range()
    if not compatible(range, ts.range(node), { { sr, sc, er, ec } }) then
      return false, 'Selection crosses an environment marker'
    end
  end
  for child in node:iter_children() do
    if child:named() then
      local ok, err = check_node(child, bufnr, range)
      if not ok then
        return false, err
      end
    end
  end
  return true
end

function M.surround(name, opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable then
    return false, 'Buffer is not modifiable'
  end
  local range, err = range_for(bufnr, opts)
  if not range then
    return false, err
  end
  -- At the end of a line comment, an opening marker would be commented out.
  if range[2] > 0 then
    local previous = ts.node({ pos = { range[1], range[2] - 1 } })
    while previous do
      if previous:type() == 'line_comment' then
        return false, 'A command surround cannot start at the end of a line comment'
      end
      previous = previous:parent()
    end
  end
  local node, message = ts.node({ pos = { range[1], range[2] } })
  if not node then
    return false, message
  end
  while node:parent() do
    node = node:parent()
  end
  local ok, reason = check_node(node, bufnr, range)
  if not ok then
    return false, reason
  end
  local body = contents(bufnr, range)
  return edit.with_command_name(bufnr, name, '', function(value)
    return edit.apply(bufnr, { { range = range, text = '\\' .. value .. '{' .. body .. '}' } })
  end)
end

function M.surround_visual(name)
  local mode = vim.fn.mode()
  if mode ~= 'v' and mode ~= 'V' then
    return false, 'Use a characterwise or linewise Visual selection'
  end
  local anchor, cursor = vim.fn.getpos('v'), vim.fn.getpos('.')
  local opts = {
    type = mode,
    exclusive = vim.o.selection == 'exclusive',
  }
  local regions = vim.fn.getregionpos(anchor, cursor, opts)
  if #regions == 0 then
    return false, 'Select nonempty text'
  end
  local first, last = regions[1][1], regions[#regions][2]
  if first[4] ~= 0 or last[4] ~= 0 then
    return false, 'Partial characters and virtual-space selections are not supported'
  end
  local sr, sc, er = first[2] - 1, math.max(0, first[3] - 1), last[2] - 1
  -- Neovim includes composing marks and whole multibyte characters here.
  local selected = vim.fn.getregion(anchor, cursor, opts)
  local ec = math.max(0, regions[#regions][1][3] - 1) + #selected[#selected]
  local range = range_for(vim.api.nvim_get_current_buf(), { range = { sr, sc, er, ec } })
  if not range or contents(0, range) ~= table.concat(selected, '\n') then
    return false, 'Virtual-space selections are not supported'
  end
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
  return M.surround(name, { range = range })
end

return M
