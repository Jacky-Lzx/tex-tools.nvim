local environment = require('tex-tools.environment')
local M = {}

---Return a zero-based, byte-column, end-exclusive environment range.
function M.environment_range(inner)
  local env, err = environment.current()
  if not env then
    return nil, err
  end
  if not inner then
    return { env.node:range() }
  end
  local _, _, sr, sc = env.begin_node:range()
  local er, ec = env.end_node:range()
  local start_line = vim.api.nvim_buf_get_lines(env.bufnr, sr, sr + 1, false)[1]
  local end_line = vim.api.nvim_buf_get_lines(env.bufnr, er, er + 1, false)[1]
  -- For markers on their own lines, select the body without marker newlines.
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

function M.select_environment(inner)
  local range, err = M.environment_range(inner)
  if not range then
    -- Cancel an operator instead of letting it consume a fallback motion.
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
    return false, err
  end
  local sr, sc, er, ec = unpack(range)
  if ec == 0 and er > sr then
    er = er - 1
    ec = #vim.api.nvim_buf_get_lines(0, er, er + 1, false)[1]
  end
  local line = vim.api.nvim_buf_get_lines(0, er, er + 1, false)[1]
  -- Normal/Visual cursor columns must point to the first byte of a character.
  local last = math.max(0, ec - 1)
  while last > 0 and (line:byte(last + 1) or 0) >= 128 and (line:byte(last + 1) or 0) < 192 do
    last = last - 1
  end
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
  end
  vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
  vim.cmd.normal({ 'v', bang = true })
  -- Respect 'selection=exclusive' so operators do not drop the final character.
  vim.api.nvim_win_set_cursor(0, { er + 1, vim.o.selection == 'exclusive' and ec or last })
  return true
end

return M
