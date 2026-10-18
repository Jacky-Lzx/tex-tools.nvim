local ts = require('tex-tools.treesitter')
local environment = require('tex-tools.environment')
local M = {}

local supported = { itemize = true, enumerate = true, description = true }
local pending = {}

local function clear_pending(bufnr)
  local ids = pending[bufnr]
  pending[bufnr] = nil
  for _, id in ipairs(ids or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
end

-- InsertCharPre runs after Insert mode establishes its undo boundary. Join
-- only the first typed character, and discard the hook after any other edit,
-- cursor movement, or mode/buffer change.
local function join_first_character(bufnr)
  clear_pending(bufnr)
  if vim.fn.eval('&undolevels') < 0 then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local function unchanged()
    return vim.api.nvim_buf_get_changedtick(bufnr) == tick and vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0))
  end
  local group = vim.api.nvim_create_augroup('TexToolsListUndo', { clear = false })
  pending[bufnr] = {
    vim.api.nvim_create_autocmd('InsertCharPre', {
      group = group,
      buffer = bufnr,
      once = true,
      callback = function()
        if unchanged() then
          vim.cmd.undojoin()
        end
        clear_pending(bufnr)
      end,
    }),
    vim.api.nvim_create_autocmd(
      { 'InsertLeave', 'BufLeave', 'BufWipeout', 'CursorMovedI', 'CursorMoved', 'TextChangedI', 'TextChanged' },
      {
        group = group,
        buffer = bufnr,
        callback = function(event)
          if
            event.event == 'InsertLeave'
            or event.event == 'BufLeave'
            or event.event == 'BufWipeout'
            or not unchanged()
          then
            clear_pending(bufnr)
          end
        end,
      }
    ),
  }
end

local function before(ar, ac, br, bc)
  return ar < br or (ar == br and ac < bc)
end

local function line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
end

local function leading_indent(bufnr, row)
  return line(bufnr, row):match('^[ \t]*')
end

local function body_indent(bufnr, env)
  local row = env.begin_node:range()
  local indent = leading_indent(bufnr, row)
  local width = vim.fn.strdisplaywidth(indent)
  local target = width + vim.fn.shiftwidth()
  if not vim.bo[bufnr].expandtab then
    local next_width = vim.fn.strdisplaywidth(indent .. '\t')
    while next_width <= target do
      indent, width = indent .. '\t', next_width
      next_width = vim.fn.strdisplaywidth(indent .. '\t')
    end
  end
  return indent .. string.rep(' ', target - width)
end

local function current()
  local node, err = ts.editable_node()
  if not node then
    return nil, err
  end
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node then
    return nil, 'No surrounding LaTeX list'
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local env, message = environment.from_node(node, bufnr)
  if not env then
    return nil, message
  end
  if not supported[env.name] then
    return nil, 'The nearest environment must be itemize, enumerate, or description'
  end
  if node:has_error() then
    return nil, 'List syntax is incomplete'
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local _, _, br, bc = env.begin_node:range()
  local er, ec = env.end_node:range()
  if not ts.contains({ br, bc, er, ec }, row, col) then
    return nil, 'Place the cursor inside the list body'
  end
  local item, has_items
  for child in node:iter_children() do
    local cr, cc = child:range()
    if child:type() == 'enum_item' then
      has_items = true
      if not before(row, col, cr, cc) then
        item = child
      end
    elseif
      before(cr, cc, row, col)
      and child:type() ~= 'begin'
      and child:type() ~= 'end'
      and not ts.comment_types[child:type()]
    then
      -- Do not attach an item to unrelated structural content in a malformed list.
      item = nil
    end
  end
  if not item then
    local body = table.concat(vim.api.nvim_buf_get_text(bufnr, br, bc, er, ec, {}), '\n')
    if has_items or not body:match('^%s*$') then
      return nil, 'No current list item'
    end
  end
  return { env = env, item = item, bufnr = bufnr }
end

---Insert after the entire current item, place the cursor, and enter Insert mode.
function M.insert()
  local context, err = current()
  if not context then
    return false, err
  end
  local bufnr, env, item = context.bufnr, context.env, context.item
  if not vim.bo[bufnr].modifiable then
    return false, 'Buffer is not modifiable'
  end
  -- Synchronize the undo block without changing the option or clearing history.
  -- Text typed in the old item must remain separate from the new sibling.
  vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels

  local indent = body_indent(bufnr, env)
  local row, boundary, boundary_col
  if item then
    local sr, sc, er = item:range()
    local prefix = line(bufnr, sr):sub(1, sc)
    if prefix:match('^[ \t]*$') then
      indent = prefix
    end
    row = er
    -- Extra comments can be siblings rather than part of an enum_item.
    -- Keep trailing comments on their original line when adding a new item.
    boundary = item:next_named_sibling()
    while boundary and ts.comment_types[boundary:type()] do
      boundary = boundary:next_named_sibling()
    end
    boundary = boundary or env.end_node
    local boundary_row
    boundary_row, boundary_col = boundary:range()
    if boundary_row ~= row then
      boundary = nil
    end
  else
    -- An empty list gets its first item immediately before the end marker.
    boundary = env.end_node
    row, boundary_col = boundary:range()
  end

  local description = env.name == 'description'
  local marker = indent .. (description and '\\item[] ' or '\\item ')
  local target_row
  if boundary then
    local prefix = line(bufnr, row):sub(1, boundary_col)
    if not item and prefix:match('^[ \t]*$') then
      vim.api.nvim_buf_set_lines(bufnr, row, row, false, { marker })
      target_row = row
    else
      local begin_row = env.begin_node:range()
      local tail_indent = boundary:type() == 'end' and leading_indent(bufnr, begin_row) or indent
      local ok, message = require('tex-tools.edit').apply(bufnr, {
        {
          range = { row, boundary_col, row, boundary_col },
          text = '\n' .. marker .. '\n' .. tail_indent,
        },
      })
      if not ok then
        return false, message
      end
      target_row = row + 1
    end
  else
    vim.api.nvim_buf_set_lines(bufnr, row + 1, row + 1, false, { marker })
    target_row = row + 1
  end
  local col = description and (#indent + #'\\item[') or (#marker - 1)
  vim.api.nvim_win_set_cursor(0, { target_row + 1, col })
  vim.cmd.startinsert({ bang = not description })
  join_first_character(bufnr)
  return true
end

return M
