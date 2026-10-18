local M = {}

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
  })
end

return M
