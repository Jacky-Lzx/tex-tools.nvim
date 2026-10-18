local ts = require('tex-tools.treesitter')
local M = {}
M.levels = { 'part', 'chapter', 'section', 'subsection', 'subsubsection', 'paragraph', 'subparagraph' }
local kinds = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}

function M.current(opts, count)
  local node, err = ts.editable_node(opts)
  local bufnr = ts.buffer(opts and opts.bufnr)
  while node do
    if kinds[node:type()] then
      local header, message = require('tex-tools.structure').command_node(node, bufnr)
      if message or not header or not ts.field(node, 'text') then
        return nil, message or 'Section heading is incomplete'
      end
      count = count - 1
      if count == 0 then
        local outer = ts.range(node)
        local sr, sc = header.outer[3], header.outer[4]
        local er, ec = outer[3], outer[4]
        local lines = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
        if sr < er and lines[1]:sub(sc + 1):match('^%s*$') then
          sr, sc = sr + 1, 0
        end
        local first = vim.api.nvim_buf_get_lines(bufnr, outer[1], outer[1] + 1, false)[1]
        local last = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1]
        if first:sub(1, outer[2]):match('^%s*$') and last:sub(ec + 1):match('^%s*$') then
          outer[2] = 0
          if er + 1 < vim.api.nvim_buf_line_count(bufnr) then
            outer[3], outer[4] = er + 1, 0
          end
        end
        return { outer = outer, inner = { sr, sc, er, ec }, node = node }
      end
    end
    node = node:parent()
  end
  return nil, err or 'Not enough enclosing LaTeX sections'
end
-- Shared by structural edits and outline discovery. Do not interpret headings
-- in definitions, comments or verbatim as document sections.
function M.blocked(node)
  local kind = node:type()
  if ts.comment_types[kind] or ts.literal_types[kind] or kind:match('_definition$') then
    return true
  end
  if kind == 'curly_group' then
    local previous = node:prev_named_sibling()
    if previous and previous:type() == 'text' then
      previous = previous:prev_named_sibling()
    end
    return previous and previous:type() == 'old_command_definition' or false
  end
  return false
end

function M.is_heading(node)
  return kinds[node:type()] == true
end

function M.shift(direction, count)
  count = count or 1
  if
    (direction ~= 1 and direction ~= -1)
    or type(count) ~= 'number'
    or count < 1
    or count == math.huge
    or count % 1 ~= 0
  then
    return false, 'Use direction -1 (promote) or 1 (demote), and a positive integer count'
  end
  local section, err = M.current(nil, 1)
  if not section then
    return false, err
  end
  local ancestor = section.node
  while ancestor do
    if M.blocked(ancestor) then
      return false, 'No section editing in comments, literal content or definitions'
    end
    ancestor = ancestor:parent()
  end
  local changes, failure = {}, nil
  local function visit(node)
    if M.blocked(node) then
      return
    end
    if M.is_heading(node) then
      local command, title, toc = ts.field(node, 'command'), ts.field(node, 'text'), ts.field(node, 'toc')
      local level = vim.fn.index(M.levels, node:type()) + 1
      local target = M.levels[level + direction * count]
      if not target then
        failure = 'Section shift would exceed part/subparagraph boundaries'
        return
      end
      if not command or command:missing() or not title or title:has_error() or (toc and toc:has_error()) then
        failure = 'Section heading is incomplete'
        return
      end
      local star = ts.text(command, 0):sub(-1) == '*' and '*' or ''
      changes[#changes + 1] = { range = ts.range(command), text = '\\' .. target .. star }
    end
    for child in node:iter_children() do
      visit(child)
    end
  end
  visit(section.node)
  if failure then
    return false, failure
  end
  return require('tex-tools.edit').apply(
    vim.api.nvim_get_current_buf(),
    changes,
    { module = 'section', method = 'shift', args = { direction, count } }
  )
end

return M
