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

function M.argument(opts)
  local node, err = ts.editable_node(opts)
  while node do
    if group(node) then
      return group_ranges(node)
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX argument'
end

function M.command(opts)
  local node, err = ts.editable_node(opts)
  local pos = opts and opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  while node do
    local command = ts.field(node, 'command')
    local kind = node:type()
    if
      command
      and not group(node)
      and kind ~= 'begin'
      and kind ~= 'end'
      and ts.text(command, opts and opts.bufnr):sub(1, 1) == '\\'
    then
      local sr, sc, er, ec = command:range()
      local invalid = command:missing()
      -- Section/item nodes also contain their body. Only field-owned groups
      -- belong to the command call; never include the section's body children.
      for child, field in node:iter_children() do
        if field and group(child) then
          local cr, cc, lr, lc = child:range()
          if cr > sr or (cr == sr and cc > sc) then
            if lr > er or (lr == er and lc > ec) then
              er, ec = lr, lc
            end
            invalid = invalid or group_ranges(child) == nil
          end
        end
      end
      local outer = { sr, sc, er, ec }
      if ts.contains(outer, pos[1], pos[2]) then
        if invalid then
          return nil, 'Command arguments are incomplete'
        end
        local _, _, nr, nc = command:range()
        return { node = node, outer = outer, inner = { sr, sc + 1, nr, nc } }
      end
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX command'
end

function M.math(opts)
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
      return {
        node = node,
        outer = ts.range(node),
        inner = { sr, sc, er, ec },
        opening = ts.range(first),
        closing = ts.range(last),
        delimiter = first:type(),
      }
    elseif require('tex-tools.context').is_math_environment(node, opts and opts.bufnr) then
      local environment = require('tex-tools.environment')
      local env, message = environment.from_node(node, ts.buffer(opts and opts.bufnr))
      if not env then
        return nil, message
      end
      return { node = node, outer = ts.range(node), inner = environment.body_range(env) }
    end
    node = node:parent()
  end
  return nil, err or 'No surrounding LaTeX formula'
end

return M
