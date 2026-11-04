-- Return plain formula snapshots from the same Tree-sitter semantics used by
-- tex-tools editing. No TSNodes escape this module and no rendering occurs here.
local M = {}
local ts = require('tex-tools.treesitter')

-- Some LaTeX parser versions expose inline verbatim as a command followed by
-- ordinary formula nodes. Resolve only this lexical gap on the candidate line.
local function inline_literal(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local pos = 1
  while pos <= #line do
    local first, last, name = line:find('\\([%a@]+%*?)', pos)
    if not first or first > col + 1 then
      return false
    end
    local previous, escaped = first - 1, false
    while line:sub(previous, previous) == '\\' do
      escaped = not escaped
      previous = previous - 1
    end
    if not escaped and (name:match('^verb%*?$') or name:match('^lstinline%*?$') or name == 'mintinline') then
      local start = last + 1
      if not name:match('^verb') then
        start = start + #(line:match('^%s*%b[]%s*', start) or line:match('^%s*', start) or '')
        if name == 'mintinline' then
          local language = line:match('^%b{}%s*', start)
          start = language and start + #language or #line + 1
        end
      end
      local delimiter = line:sub(start, start)
      local group = not name:match('^verb') and line:match('^%b{}', start)
      local finish = group and start + #group - 1
        or (delimiter ~= '' and line:find(delimiter, start + 1, true))
        or #line
      if col + 1 <= finish then
        return true
      end
      pos = finish + 1
    else
      pos = last + 1
    end
  end
  return false
end

function M.find(bufnr, row, col, options)
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'tex' and ft ~= 'plaintex' and ft ~= 'latex' then
    return nil, 'Formula preview supports LaTeX buffers'
  end
  local node, err = ts.editable_node({ bufnr = bufnr, pos = { row, col } })
  if not node then
    return nil, err
  end
  local ancestor = node
  while ancestor do
    if ancestor:type():match('_definition$') then
      return nil, 'Formula definitions are not previewed'
    end
    ancestor = ancestor:parent()
  end
  if inline_literal(bufnr, row, col) then
    return nil, 'Inline verbatim is not previewed'
  end
  local structure = require('tex-tools.structure')
  local formula = structure.math({ bufnr = bufnr, pos = { row, col } })
  if not formula then
    -- Match the first covering formula on this line when the cursor is outside
    -- one, without scanning source characters or parsing TeX a second way.
    local root = ts.root(bufnr)
    local function visit(current)
      local sr, _, er = current:range()
      if
        sr > row
        or er < row
        or ts.comment_types[current:type()]
        or ts.literal_types[current:type()]
        or current:type():match('_definition$')
      then
        return
      end
      if
        current:type() == 'inline_formula'
        or current:type() == 'displayed_equation'
        or require('tex-tools.context').is_math_environment(current, bufnr)
      then
        local r, c = current:range()
        if not inline_literal(bufnr, r, c) then
          return structure.math({ bufnr = bufnr, pos = { r, c } })
        end
        return
      end
      for child in current:iter_children() do
        if child:named() then
          local found = visit(child)
          if found then
            return found
          end
        end
      end
    end
    formula = root and visit(root)
  end
  if not formula or formula.node:has_error() then
    return nil, 'No complete formula on the current line'
  end
  local range = formula.outer
  if range[3] - range[1] + 1 > options.max_lines then
    return nil, 'Formula exceeds formula_preview.max_lines'
  end
  local source = table.concat(vim.api.nvim_buf_get_text(bufnr, range[1], range[2], range[3], range[4], {}), '\n')
  if #source > options.max_bytes then
    return nil, 'Formula exceeds formula_preview.max_bytes'
  end
  return { source = source, range = range, key = vim.fn.sha256(source) }
end

return M
