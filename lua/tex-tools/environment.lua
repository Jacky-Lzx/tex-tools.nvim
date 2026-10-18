local ts = require('tex-tools.treesitter')
local edit = require('tex-tools.edit')
local M = {}

---@param opts? {bufnr?: integer, pos?: integer[]}
---@return table?, string?
function M.current(opts)
  opts = opts or {}
  local bufnr = ts.buffer(opts.bufnr)
  local node, err = ts.node(opts)
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node then
    return nil, err or 'No surrounding LaTeX environment'
  end
  return M.from_node(node, bufnr)
end

function M.from_node(node, bufnr)
  local begin_node, end_node = ts.field(node, 'begin'), ts.field(node, 'end')
  if not begin_node or not end_node or end_node:missing() then
    return nil, 'Environment is incomplete'
  end
  local begin_name = ts.field(ts.field(begin_node, 'name'), 'text')
  local end_name = ts.field(ts.field(end_node, 'name'), 'text')
  if not begin_name or not end_name or begin_name:missing() or end_name:missing() then
    return nil, 'Environment name is incomplete'
  end
  local name = ts.text(begin_name, bufnr)
  if name == '' or name ~= ts.text(end_name, bufnr) then
    return nil, 'Environment begin/end names do not match'
  end
  return {
    bufnr = bufnr,
    node = node,
    name = name,
    begin_node = begin_node,
    end_node = end_node,
    begin_name = begin_name,
    end_name = end_name,
  }
end

local function rename(env, name)
  if not edit.environment_name(name) then
    return false, 'Use a literal environment name, e.g. equation*'
  end
  return edit.apply(env.bufnr, {
    { range = ts.range(env.begin_name), text = name },
    { range = ts.range(env.end_name), text = name },
  })
end

---@param name? string Prompt with vim.ui.input when omitted.
---@return boolean, string?
function M.rename(name)
  local env, err = M.current()
  if not env then
    return false, err
  end
  return edit.with_environment_name(env.bufnr, name, env.name, function(value)
    return rename(env, value)
  end)
end

---Return the body range without standalone marker lines or begin options.
function M.body_range(env)
  local _, _, sr, sc = env.begin_node:range()
  local er, ec = env.end_node:range()
  local start_line = vim.api.nvim_buf_get_lines(env.bufnr, sr, sr + 1, false)[1]
  local end_line = vim.api.nvim_buf_get_lines(env.bufnr, er, er + 1, false)[1]
  if sr < er and start_line:sub(sc + 1):match('^%s*$') then
    sr, sc = sr + 1, 0
  end
  if sr < er and end_line:sub(1, ec):match('^%s*$') then
    er = er - 1
    ec = #vim.api.nvim_buf_get_lines(env.bufnr, er, er + 1, false)[1]
  end
  if sr > er or (sr == er and sc >= ec) then
    return nil, 'Environment body is empty'
  end
  return { sr, sc, er, ec }
end

---Surround a one-based inclusive line range, defaulting to the current line.
function M.surround(name, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local first = opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
  local last = opts.line2 or first
  if
    type(first) ~= 'number'
    or type(last) ~= 'number'
    or first % 1 ~= 0
    or last % 1 ~= 0
    or first < 1
    or last < first
    or last > vim.api.nvim_buf_line_count(bufnr)
  then
    return false, 'Invalid line range'
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local indent = lines[1]:match('^%s*')
  return edit.with_environment_name(bufnr, name, '', function(value)
    local text = indent
      .. '\\begin{'
      .. value
      .. '}\n'
      .. table.concat(lines, '\n')
      .. '\n'
      .. indent
      .. '\\end{'
      .. value
      .. '}'
    return edit.apply(bufnr, { { range = { first - 1, 0, last - 1, #lines[#lines] }, text = text } })
  end)
end

function M.surround_visual()
  local first, last = vim.fn.line('v'), vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
  return M.surround(nil, { line1 = math.min(first, last), line2 = math.max(first, last) })
end

function M.unwrap()
  local env, err = M.current()
  if not env then
    return false, err
  end
  if not vim.bo[env.bufnr].modifiable then
    return false, 'Buffer is not modifiable'
  end
  local sr, sc, br, bc = env.begin_node:range()
  local cr, cc, er, ec = env.end_node:range()
  local function line(row)
    return vim.api.nvim_buf_get_lines(env.bufnr, row, row + 1, false)[1]
  end
  local opening_line = line(sr):sub(1, sc):match('^%s*$') and line(br):sub(bc + 1):match('^%s*$')
  local closing_line = line(cr):sub(1, cc):match('^%s*$') and line(er):sub(ec + 1):match('^%s*$')
  local body = vim.api.nvim_buf_get_text(env.bufnr, br, bc, cr, cc, {})
  if opening_line then
    table.remove(body, 1)
  end
  if closing_line then
    table.remove(body)
  end
  if opening_line and closing_line then
    vim.api.nvim_buf_set_lines(env.bufnr, sr, er + 1, false, body)
    return true
  end
  return edit.apply(env.bufnr, {
    {
      range = { sr, opening_line and 0 or sc, er, closing_line and #line(er) or ec },
      text = table.concat(body, '\n'),
    },
  })
end

function M.toggle_star()
  local env, err = M.current()
  if not env then
    return false, err
  end
  local name = env.name:sub(-1) == '*' and env.name:sub(1, -2) or (env.name .. '*')
  return rename(env, name)
end

---Jump from the end marker to the begin marker, or from the body/begin to end.
function M.jump()
  local env, err = M.current()
  if not env then
    return false, err
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local er, ec = env.end_node:range()
  local target = (row > er or (row == er and col >= ec)) and env.begin_node or env.end_node
  local tr, tc = target:range()
  vim.cmd.normal({ "m'", bang = true })
  vim.api.nvim_win_set_cursor(0, { tr + 1, tc })
  return true
end

return M
