local environment = require('tex-tools.environment')
local ts = require('tex-tools.treesitter')
local M = {}

local function depth(opts)
  local count = opts and opts.count
  count = count == nil and 1 or count
  if type(count) ~= 'number' or count < 1 or count == math.huge or count % 1 ~= 0 then
    return nil, 'Count must be a positive integer'
  end
  return count
end

---Return a zero-based, byte-column, end-exclusive environment range.
function M.environment_range(inner, opts)
  local count, message = depth(opts)
  if not count then
    return nil, message
  end
  local env, err = environment.current(opts)
  if not env then
    return nil, err
  end
  for _ = 2, count do
    local node = env.node:parent()
    while node and not ts.environment(node) do
      node = node:parent()
    end
    if not node then
      return nil, 'Not enough enclosing LaTeX environments'
    end
    env, err = environment.from_node(node, env.bufnr)
    if not env then
      return nil, err
    end
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
  if kind ~= 'command' and kind ~= 'argument' and kind ~= 'math' and kind ~= 'delimiter' and kind ~= 'item' then
    return nil, 'Unknown text object: ' .. tostring(kind)
  end
  local count, message = depth(opts)
  if not count then
    return nil, message
  end
  local object, err
  if kind == 'delimiter' then
    object, err = require('tex-tools.delimiter').current(opts, count)
  elseif kind == 'item' then
    object, err = require('tex-tools.item').current(opts, count)
  else
    object, err = require('tex-tools.structure')[kind](opts, count)
  end
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

function M.select(kind, inner, count)
  local range, err = M.range(kind, inner, { count = count })
  if not range then
    -- Cancel an operator instead of letting it consume a fallback motion.
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
    return false, err
  end
  local sr, sc, er, ec = unpack(range)
  local whole_lines = kind == 'item' and not inner and sc == 0 and ec == 0 and er > sr
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
  if whole_lines then
    -- Keep the final newline in whole-item operators under both selection modes.
    vim.cmd.normal({ 'V', bang = true })
    vim.api.nvim_win_set_cursor(0, { er + 1, 0 })
    return true
  end
  vim.cmd.normal({ 'v', bang = true })
  -- Respect 'selection=exclusive' so operators do not drop the final character.
  vim.api.nvim_win_set_cursor(0, { er + 1, vim.o.selection == 'exclusive' and ec or last })
  return true
end

function M.select_environment(inner, count)
  return M.select('environment', inner, count)
end

---Expression mapping: cancel before a failed operator creates an empty edit.
function M.mapping(kind, inner, count)
  count = count == nil and 1 or count
  local range, err = M.range(kind, inner, { count = count })
  if not range then
    vim.schedule_wrap(vim.notify)(err, vim.log.levels.WARN, { title = 'tex-tools' })
    return vim.keycode('<Esc>')
  end
  -- Selection changes mode, so execute it after leaving expression textlock.
  -- Re-query at execution. Native dot replays this RHS; read its live count
  -- rather than freezing the initial depth into the recorded command.
  return vim.keycode(
    ('<Cmd>lua require("tex-tools.textobjects").select(%q, %s, vim.v.count1)<CR>'):format(kind, tostring(inner))
  )
end

return M
