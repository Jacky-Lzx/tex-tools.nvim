local M = {}

function M.convert(target, repeat_action)
  local ts = require('tex-tools.treesitter')
  local formula, err = require('tex-tools.structure').math()
  if not formula then
    return false, err
  end
  local environments = {
    equation = true,
    ['equation*'] = true,
    align = true,
    ['align*'] = true,
    gather = true,
    ['gather*'] = true,
    multline = true,
    ['multline*'] = true,
    math = true,
    displaymath = true,
  }
  for _, name in ipairs(require('tex-tools.config').options.math_environments) do
    environments[name] = true
  end
  if target ~= 'inline' and target ~= 'display' and not environments[target] then
    return false, 'Use inline, display or a supported math environment'
  end
  if not formula.inner then
    return false, 'Formula body is empty'
  end
  if not formula.delimiter then
    local env = require('tex-tools.environment').from_node(formula.node, 0)
    local name = ts.field(env.begin_node, 'name')
    local _, _, nr, nc = name:range()
    local _, _, br, bc = env.begin_node:range()
    if table.concat(vim.api.nvim_buf_get_text(0, nr, nc, br, bc, {}), '\n'):match('%S') then
      return false, 'Conversion would discard environment options'
    end
  end
  local sr, sc, er, ec = unpack(formula.inner)
  local body = table.concat(vim.api.nvim_buf_get_text(0, sr, sc, er, ec, {}), '\n')
  local alignment = target == 'align' or target == 'align*'
  if not alignment and (body:find('&', 1, true) or body:find('\\\\', 1, true)) then
    return false, 'Alignment columns or row breaks require an alignment environment'
  end
  if
    target == 'inline'
    and (body:find('\n', 1, true) or body:find('%%') or body:find('\\label', 1, true) or body:find('\\tag', 1, true))
  then
    return false, 'Inline conversion requires one line without comments, labels or tags'
  end
  local value
  if target == 'inline' then
    value = '\\(' .. body .. '\\)'
  elseif target == 'display' then
    value = body:find('\n', 1, true) or not formula.delimiter
    value = value and ('\\[\n' .. body .. '\n\\]') or ('\\[' .. body .. '\\]')
  else
    local indent = vim.api.nvim_buf_get_lines(0, formula.outer[1], formula.outer[1] + 1, false)[1]:match('^%s*')
    value = '\\begin{' .. target .. '}\n' .. body .. '\n' .. indent .. '\\end{' .. target .. '}'
  end
  return require('tex-tools.edit').apply(
    vim.api.nvim_get_current_buf(),
    { { range = formula.outer, text = value } },
    repeat_action or { module = 'math', method = 'convert', args = { target } }
  )
end

function M.toggle_mode()
  local formula, err = require('tex-tools.structure').math()
  if not formula then
    return false, err
  end
  return M.convert(
    (formula.delimiter == '$' or formula.delimiter == '\\(') and 'display' or 'inline',
    { module = 'math', method = 'toggle_mode' }
  )
end

---Switch delimiter spelling without changing inline/display math mode.
function M.toggle_delimiters()
  local formula, err = require('tex-tools.structure').math()
  if not formula then
    return false, err
  end
  local targets = {
    ['$'] = { '\\(', '\\)' },
    ['\\('] = { '$', '$' },
    ['$$'] = { '\\[', '\\]' },
    ['\\['] = { '$$', '$$' },
  }
  local target = targets[formula.delimiter]
  if not target then
    return false, 'Use environment editing for a named math environment'
  end
  return require('tex-tools.edit').apply(vim.api.nvim_get_current_buf(), {
    { range = formula.opening, text = target[1] },
    { range = formula.closing, text = target[2] },
  }, { module = 'math', method = 'toggle_delimiters' })
end

return M
