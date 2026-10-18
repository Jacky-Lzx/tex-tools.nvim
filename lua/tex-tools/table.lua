local ts = require('tex-tools.treesitter')
local edit = require('tex-tools.edit')
local M = {}

local function text(bufnr, range)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, range[1], range[2], range[3], range[4], {}), '\n')
end

local function trim(bufnr, range)
  local source = text(bufnr, range)
  local leading = #source:match('^%s*')
  if leading == #source then
    leading = #(source:match('^(.*\n)') or '')
  end
  local ending = math.max(leading, #source - #source:match('%s*$'))
  local function position(offset)
    local row, col = range[1], range[2]
    for char in source:sub(1, offset):gmatch('.') do
      if char == '\n' then
        row, col = row + 1, 0
      else
        col = col + 1
      end
    end
    return row, col
  end
  local sr, sc = position(leading)
  local er, ec = position(ending)
  return { sr, sc, er, ec }
end

function M.layout(opts)
  local structure, err = require('tex-tools.table_context').structure(opts)
  if not structure then
    return nil, err
  end
  local bufnr = structure.env.bufnr
  local rows, cells = {}, {}
  local sr, sc, er, ec = unpack(structure.body)
  local start = { sr, sc }
  local row_start = { sr, sc }
  local function cell(finish)
    local outer = { start[1], start[2], finish[1], finish[2] }
    local item = { outer = outer, inner = trim(bufnr, outer), row = #rows + 1, column = #cells + 1 }
    cells[#cells + 1] = item
  end
  local function row(finish, ending)
    cell(finish)
    rows[#rows + 1] = { cells = cells, start = row_start, finish = finish, ending = ending }
    cells = {}
  end
  local has_rules = false
  for _, boundary in ipairs(structure.boundaries) do
    local r = boundary.range
    if boundary.kind == 'rule' then
      -- Rules are outside cells. Editing tables containing them is conservative.
      has_rules = true
      if #cells == 0 and text(bufnr, { start[1], start[2], r[1], r[2] }):match('^%s*$') then
        start, row_start = { r[3], r[4] }, { r[3], r[4] }
      end
    elseif boundary.kind == 'cell' then
      cell({ r[1], r[2] })
      start = { r[3], r[4] }
    else
      row({ r[1], r[2] }, r)
      start, row_start = { r[3], r[4] }, { r[3], r[4] }
    end
  end
  if #cells > 0 or not text(bufnr, { start[1], start[2], er, ec }):match('^%s*$') then
    row({ er, ec })
  end
  structure.rows, structure.has_rules = rows, has_rules
  return structure
end

function M.current(opts, count)
  if count and count ~= 1 then
    return nil, 'Cell objects support count 1 only'
  end
  local layout, err = M.layout(opts)
  if not layout then
    return nil, err
  end
  local pos = opts and opts.pos
  if not pos then
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  for _, boundary in ipairs(layout.boundaries) do
    if ts.contains(boundary.range, unpack(pos)) then
      return nil, 'Cursor is on a table separator or rule'
    end
  end
  for _, row in ipairs(layout.rows) do
    for _, cell in ipairs(row.cells) do
      local r = cell.outer
      if ts.contains(r, unpack(pos)) or (pos[1] == r[3] and pos[2] == r[4] and r[1] == r[3] and r[2] == r[4]) then
        return cell, layout
      end
    end
  end
  return nil, 'Cursor is outside table cells'
end

function M.jump(direction, count)
  count = count or 1
  if
    (direction ~= 1 and direction ~= -1)
    or type(count) ~= 'number'
    or count < 1
    or count == math.huge
    or count % 1 ~= 0
  then
    return false, 'Use direction 1 or -1 and a positive integer count'
  end
  local cell, layout = M.current()
  if not cell then
    return false, layout
  end
  local flat, current = {}, nil
  for _, row in ipairs(layout.rows) do
    for _, item in ipairs(row.cells) do
      flat[#flat + 1] = item
      if item.row == cell.row and item.column == cell.column then
        current = #flat
      end
    end
  end
  local target = flat[current + direction * count]
  if not target then
    return false, 'No cell at the requested position'
  end
  vim.cmd.normal({ "m'", bang = true })
  vim.api.nvim_win_set_cursor(0, { target.inner[1] + 1, target.inner[2] })
  vim.cmd.normal({ 'zv', bang = true })
  return true
end

local function regular(layout)
  if layout.has_rules then
    return nil, 'Row/column edits require a table without rule commands'
  end
  local function unsafe(node)
    local kind = node:type()
    if ts.comment_types[kind] or ts.literal_types[kind] or (node ~= layout.env.node and ts.environment(node)) then
      return true
    end
    local command = ts.field(node, 'command')
    if
      command
      and vim.tbl_contains({ '\\multicolumn', '\\multirow', '\\omit', '\\span' }, ts.text(command, layout.env.bufnr))
    then
      return true
    end
    for child in node:iter_children() do
      if unsafe(child) then
        return true
      end
    end
    return false
  end
  if unsafe(layout.env.node) then
    return nil, 'Row/column edits do not support comments, nested environments, or spans'
  end
  local width = #layout.rows[1].cells
  local previous = -1
  for _, row in ipairs(layout.rows) do
    local first = row.cells[1].inner
    local last = row.cells[#row.cells].inner
    local sr, er = first[1], row.ending and row.ending[3] or last[3]
    local ec = row.ending and row.ending[4] or last[4]
    local line = vim.api.nvim_buf_get_lines(layout.env.bufnr, sr, sr + 1, false)[1]
    local endline = vim.api.nvim_buf_get_lines(layout.env.bufnr, er, er + 1, false)[1]
    if
      sr ~= er
      or sr <= previous
      or #row.cells ~= width
      or not line:sub(1, first[2]):match('^%s*$')
      or not endline:sub(ec + 1):match('^%s*$')
    then
      return nil, 'Row/column edits require equal-width rows, each on its own line'
    end
    row.line, row.indent, row.endcol = sr, line:sub(1, first[2]), ec
    previous = er
  end
  return width
end

function M.edit(operation)
  if not vim.tbl_contains({ 'insert_row', 'delete_row', 'insert_column', 'delete_column' }, operation) then
    return false, 'Unknown table edit'
  end
  local cell, layout = M.current()
  if not cell then
    return false, layout
  end
  local width, err = regular(layout)
  if not width then
    return false, err
  end
  local bufnr, changes = layout.env.bufnr, {}
  local row = layout.rows[cell.row]
  if operation == 'insert_row' then
    local blank = row.indent .. table.concat(vim.fn['repeat']({ ' ' }, width), ' & ') .. ' \\\\'
    if not row.ending then
      changes[#changes + 1] = { range = { row.line, row.endcol, row.line, row.endcol }, text = ' \\\\' }
    end
    changes[#changes + 1] = { range = { row.line + 1, 0, row.line + 1, 0 }, text = blank .. '\n' }
  elseif operation == 'delete_row' then
    if #layout.rows == 1 then
      return false, 'Cannot delete the only row'
    end
    changes[1] = { range = { row.line, 0, row.line + 1, 0 }, text = '' }
  else
    local name = layout.env.name:gsub('%*$', '')
    if
      not vim.tbl_contains({
        'tabular',
        'tabularx',
        'array',
        'matrix',
        'pmatrix',
        'bmatrix',
        'Bmatrix',
        'vmatrix',
        'Vmatrix',
        'smallmatrix',
      }, name)
    then
      return false, 'Column edits support tabular, array, and matrix environments only'
    end
    if operation == 'delete_column' and width == 1 then
      return false, 'Cannot delete the only column'
    end
    if layout.column_spec then
      local r = layout.column_spec
      local spec = text(bufnr, r):sub(2, -2)
      if not spec:match('^[lcrX]+$') or #spec ~= width then
        return false, 'Column edits require a plain l/c/r/X column specification matching the rows'
      end
      local col = cell.column
      local replacement = operation == 'insert_column' and (spec:sub(1, col) .. spec:sub(col, col) .. spec:sub(col + 1))
        or (spec:sub(1, col - 1) .. spec:sub(col + 1))
      changes[#changes + 1] = { range = r, text = '{' .. replacement .. '}' }
    end
    for _, item in ipairs(layout.rows) do
      local values = {}
      for _, entry in ipairs(item.cells) do
        values[#values + 1] = text(bufnr, entry.inner)
      end
      if operation == 'insert_column' then
        table.insert(values, cell.column + 1, '')
      else
        table.remove(values, cell.column)
      end
      local ending = item.ending and (' ' .. text(bufnr, item.ending)) or ''
      changes[#changes + 1] = {
        range = { item.line, 0, item.line, item.endcol },
        text = item.indent .. table.concat(values, ' & ') .. ending,
      }
    end
  end
  return edit.apply(bufnr, changes, { module = 'table', method = 'edit', args = { operation } })
end

return M
