local ts = require('tex-tools.treesitter')
local M = {}

local function group(node)
  return node:type():match('^curly_group') or node:type():match('^brack_group')
end

local function group_ranges(node)
  local first, last = node:child(0), node:child(node:child_count() - 1)
  if not first or not last or node:has_error() or last:missing() then
    return nil, 'Argument is incomplete'
  end
  local pairs = { ['{'] = '}', ['['] = ']' }
  if pairs[first:type()] ~= last:type() then
    return nil, 'Argument delimiters do not match'
  end
  local _, _, sr, sc = first:range()
  local er, ec = last:range()
  return { node = node, outer = ts.range(node), inner = { sr, sc, er, ec } }
end

function M.group_node(node)
  if group(node) then
    return group_ranges(node)
  end
end

function M.argument(opts, count)
  count = count or 1
  local node, err = ts.editable_node(opts)
  while node do
    if group(node) then
      local object, message = group_ranges(node)
      if not object then
        return nil, message
      end
      count = count - 1
      if count == 0 then
        return object
      end
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX argument'
end

---Inspect a command header without including section/item body children.
function M.command_node(node, bufnr)
  local command = ts.field(node, 'command')
  local kind = node:type()
  if not command or group(node) or kind == 'begin' or kind == 'end' or ts.text(command, bufnr):sub(1, 1) ~= '\\' then
    return nil
  end
  local sr, sc, nr, nc = command:range()
  local er, ec = nr, nc
  local invalid = command:missing()
  local arguments, other_fields = {}, false
  for child, field in node:iter_children() do
    if field and group(child) then
      local cr, cc, lr, lc = child:range()
      if cr > sr or (cr == sr and cc > sc) then
        if lr > er or (lr == er and lc > ec) then
          er, ec = lr, lc
        end
        local argument = group_ranges(child)
        invalid = invalid or argument == nil
        arguments[#arguments + 1] = { node = child, outer = ts.range(child), inner = argument and argument.inner }
      end
    elseif field and field ~= 'command' then
      other_fields = true
    end
  end
  return {
    node = node,
    outer = { sr, sc, er, ec },
    inner = { sr, sc + 1, nr, nc },
    arguments = arguments,
    other_fields = other_fields,
  },
    invalid and 'Command arguments are incomplete' or nil
end

function M.command(opts, count)
  count = count or 1
  local node, err = ts.editable_node(opts)
  local pos = opts and opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  while node do
    local object, message = M.command_node(node, opts and opts.bufnr)
    if object and ts.contains(object.outer, pos[1], pos[2]) then
      if message then
        return nil, message
      end
      count = count - 1
      if count == 0 then
        return object
      end
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX command'
end

function M.math(opts, count)
  count = count or 1
  local node, err = ts.editable_node(opts)
  while node do
    local kind = node:type()
    if kind == 'inline_formula' or kind == 'displayed_equation' then
      local first, last = node:child(0), node:child(node:child_count() - 1)
      if not first or not last or node:has_error() or first:missing() or last:missing() then
        return nil, 'Formula is incomplete'
      end
      local pairs = { ['$'] = '$', ['$$'] = '$$', ['\\('] = '\\)', ['\\['] = '\\]' }
      if pairs[first:type()] ~= last:type() then
        return nil, 'Math delimiters do not match'
      end
      local _, _, sr, sc = first:range()
      local er, ec = last:range()
      count = count - 1
      if count == 0 then
        return {
          node = node,
          outer = ts.range(node),
          inner = { sr, sc, er, ec },
          opening = ts.range(first),
          closing = ts.range(last),
          delimiter = first:type(),
        }
      end
    elseif require('tex-tools.context').is_math_environment(node, opts and opts.bufnr) then
      local environment = require('tex-tools.environment')
      local env, message = environment.from_node(node, ts.buffer(opts and opts.bufnr))
      if not env then
        return nil, message
      end
      count = count - 1
      if count == 0 then
        return { node = node, outer = ts.range(node), inner = environment.body_range(env) }
      end
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX formula'
end

return M
