local M = {}

function M.environment_name(name)
  return type(name) == 'string' and name:match('^[%a@][%w@*_-]*$') ~= nil
end

function M.command_name(name)
  return type(name) == 'string' and name:match('^[A-Za-z@]+%*?$') ~= nil
end

---Apply byte-based, end-exclusive replacements in one undo operation.
function M.apply(bufnr, changes, repeat_action)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false, 'Buffer is not loaded'
  end
  if not vim.bo[bufnr].modifiable then
    return false, 'Buffer is not modifiable'
  end
  local edits = {}
  for _, change in ipairs(changes) do
    local sr, sc, er, ec = unpack(change.range)
    local original = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), '\n')
    if original ~= change.text then
      edits[#edits + 1] = {
        range = { start = { line = sr, character = sc }, ['end'] = { line = er, character = ec } },
        newText = change.text,
      }
    end
  end
  if #edits == 0 then
    return true
  end
  vim.lsp.util.apply_text_edits(edits, bufnr, 'utf-8')
  if repeat_action then
    require('tex-tools.repeat').record(bufnr, repeat_action)
  end
  return true
end

function M.with_name(bufnr, name, default, kind, validate, message, callback)
  local function apply(value)
    if not validate(value) then
      return false, message
    end
    return callback(value)
  end
  if name ~= nil then
    return apply(name)
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  vim.ui.input({ prompt = kind .. ': ', default = default }, function(value)
    if not value or value == '' then
      return
    end
    if not vim.api.nvim_buf_is_loaded(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      vim.notify(
        'Buffer changed; run the ' .. kind:lower() .. ' operation again',
        vim.log.levels.WARN,
        { title = 'tex-tools' }
      )
      return
    end
    local ok, err = apply(value)
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'tex-tools' })
    end
  end)
  return true
end

---Resolve names without allowing delayed prompts to use stale ranges.
function M.with_environment_name(bufnr, name, default, callback)
  return M.with_name(
    bufnr,
    name,
    default,
    'Environment',
    M.environment_name,
    'Use a literal environment name, e.g. equation*',
    callback
  )
end

function M.with_command_name(bufnr, name, default, callback)
  return M.with_name(
    bufnr,
    name,
    default,
    'Command',
    M.command_name,
    'Use a command name without a backslash: ASCII letters or @, with an optional trailing *',
    callback
  )
end

function M.control_word_before(bufnr, row, col)
  local ts = require('tex-tools.treesitter')
  if col == 0 then
    return false
  end
  local node = ts.node({ bufnr = bufnr, pos = { row, col - 1 } })
  while node do
    local command = node:type() == 'command_name' and node or ts.field(node, 'command')
    if command then
      local _, _, er, ec = command:range()
      if er == row and ec == col and ts.text(command, bufnr):match('^\\[A-Za-z@]+$') then
        return true
      end
    end
    node = node:parent()
  end
  return false
end

return M
