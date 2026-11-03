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

local function parent_environment(env)
  local node = env.node:parent()
  while node and not ts.environment(node) do
    node = node:parent()
  end
  if not node then
    return nil, 'Not enough enclosing LaTeX environments'
  end
  return environment.from_node(node, env.bufnr)
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
    env, err = parent_environment(env)
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
  if
    kind ~= 'command'
    and kind ~= 'argument'
    and kind ~= 'math'
    and kind ~= 'delimiter'
    and kind ~= 'item'
    and kind ~= 'section'
    and kind ~= 'cell'
  then
    return nil, 'Unknown text object: ' .. tostring(kind)
  end
  local count, message = depth(opts)
  if not count then
    return nil, message
  end
  local object, err
  if kind == 'cell' then
    object, err = require('tex-tools.table').current(opts, count)
  elseif kind == 'section' then
    object, err = require('tex-tools.section').current(opts, count)
  elseif kind == 'delimiter' then
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

local function visual_environment(kind)
  local mode = vim.fn.mode()
  return kind == 'environment' and (mode == 'v' or mode == 'V')
end

local function before_or_equal(ar, ac, br, bc)
  return ar < br or (ar == br and ac <= bc)
end

local function selection_range(kind, inner, count)
  if not visual_environment(kind) then
    return M.range(kind, inner, { count = count })
  end
  local requested, err = depth({ count = count })
  if not requested then
    return nil, err
  end
  -- Use the actual selected bytes, including reversed/exclusive selections.
  -- The cursor alone may sit in a sibling or just beyond an end marker.
  local anchor, cursor = vim.fn.getpos('v'), vim.fn.getpos('.')
  local opts = { type = vim.fn.mode(), exclusive = vim.o.selection == 'exclusive' }
  local regions = vim.fn.getregionpos(anchor, cursor, opts)
  if #regions == 0 then
    return nil, 'Select nonempty text'
  end
  local first, last = regions[1][1], regions[#regions][1]
  local selected = vim.fn.getregion(anchor, cursor, opts)
  local sr, sc, er = first[2] - 1, math.max(0, first[3] - 1), last[2] - 1
  local ec = math.max(0, last[3] - 1) + #selected[#selected]
  local env
  env, err = environment.current({ pos = { sr, sc } })
  while env do
    local outer = { env.node:range() }
    if before_or_equal(outer[1], outer[2], sr, sc) and before_or_equal(er, ec, outer[3], outer[4]) then
      local range, message = outer, nil
      if inner then
        range, message = environment.body_range(env)
      end
      -- Keep ie usable on a begin/end marker. Grow only when the existing
      -- selection already covers the target; empty bodies still count a level.
      local covered = range
        and before_or_equal(sr, sc, range[1], range[2])
        and before_or_equal(range[3], range[4], er, ec)
      if not covered then
        requested = requested - 1
        if requested == 0 then
          return range, message
        end
      end
    end
    env, err = parent_environment(env)
  end
  return nil, err
end

function M.select(kind, inner, count)
  local range, err = selection_range(kind, inner, count)
  if not range then
    -- Cancel an operator instead of letting it consume a fallback motion.
    if not visual_environment(kind) then
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
    end
    return false, err
  end
  local sr, sc, er, ec = unpack(range)
  local whole_lines = (kind == 'item' or kind == 'section') and not inner and sc == 0 and ec == 0 and er > sr
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
  local range, err = selection_range(kind, inner, count)
  if not range then
    vim.schedule_wrap(vim.notify)(err, vim.log.levels.WARN, { title = 'tex-tools' })
    -- A command also consumes a Visual count; an empty/Ignore RHS can leave it
    -- pending and drop the selection when the next input is processed.
    return vim.keycode(visual_environment(kind) and '<Cmd>lua do end<CR>' or '<Esc>')
  end
  -- Selection changes mode, so execute it after leaving expression textlock.
  -- Re-query at execution. Native dot replays this RHS; read its live count
  -- rather than freezing the initial depth into the recorded command.
  return vim.keycode(
    ('<Cmd>lua require("tex-tools.textobjects").select(%q, %s, vim.v.count1)<CR>'):format(kind, tostring(inner))
  )
end

return M
