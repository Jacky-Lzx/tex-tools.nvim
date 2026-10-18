local environment = require('tex-tools.environment')
local M = {}

---Return a zero-based, byte-column, end-exclusive environment range.
function M.environment_range(inner, opts)
  local env, err = environment.current(opts)
  if not env then
    return nil, err
  end
  if not inner then
    return { env.node:range() }
  end
  return environment.body_range(env)
end

function M.range(kind, inner, opts)
  if kind == 'environment' then
    return M.environment_range(inner, opts)
  end
  if kind ~= 'command' and kind ~= 'argument' and kind ~= 'math' then
    return nil, 'Unknown text object: ' .. tostring(kind)
  end
  local object, err = require('tex-tools.structure')[kind](opts)
  if not object then
    return nil, err
  end
  local range
  if inner then
    range = object.inner
  else
    range = object.outer
  end
  if not range or (range[1] == range[3] and range[2] >= range[4]) then
    return nil, 'Text object is empty'
  end
  return range
end

function M.select(kind, inner)
  local range, err = M.range(kind, inner)
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

function M.select_environment(inner)
  return M.select('environment', inner)
end

return M
