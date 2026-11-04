-- One controller owns formula selection and compilation. image-tools is an
-- optional display backend, called only through its public float()/close() API.
local M = {}
local state, timer, group
local enabled = false
local last_error

local function options()
  return require('tex-tools.config').options.formula_preview
end
local function selected()
  return require('tex-tools.formula.detect').find(
    vim.api.nvim_get_current_buf(),
    vim.api.nvim_win_get_cursor(0)[1] - 1,
    vim.api.nvim_win_get_cursor(0)[2],
    options()
  )
end

local function stop_timer()
  if timer then
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end
end

function M.close()
  stop_timer()
  local previous = state
  state = nil
  if previous then
    if previous.cancel then
      previous.cancel()
    end
    if previous.view then
      previous.view:close()
    end
    if previous.image then
      previous.image.release()
    end
  end
  return true
end

local function current(captured)
  if
    state ~= captured
    or not vim.api.nvim_buf_is_valid(captured.buf)
    or vim.api.nvim_get_current_buf() ~= captured.buf
    or vim.api.nvim_get_current_win() ~= captured.win
  then
    return false
  end
  local snapshot = selected()
  return snapshot and snapshot.key == captured.key or false
end

local function fail(captured, err)
  if state ~= captured then
    return
  end
  last_error = tostring(err)
  local silent = captured.silent
  M.close()
  if not silent then
    vim.notify(last_error, vim.log.levels.WARN, { title = 'tex-tools formula' })
  end
end

local function compile(captured)
  -- A timer can already be queued on the main loop when cancelled. It may
  -- neither clear a newer timer nor restart manually expedited compilation.
  if state ~= captured or captured.started then
    return
  end
  captured.started = true
  timer = nil
  if not current(captured) then
    M.close()
    return
  end
  captured.stage = 'compiling'
  captured.cancel = require('tex-tools.formula.render').prepare(captured.source, options(), function(err, image)
    if not current(captured) then
      if image then
        image.release()
      end
      if state == captured then
        M.close()
      end
      return
    end
    if err then
      fail(captured, err)
      return
    end
    captured.image = image
    local ok, backend = pcall(require, 'image_tools')
    if not ok or type(backend.float) ~= 'function' then
      fail(captured, 'Formula preview requires image-tools.nvim with float() support')
      return
    end
    backend.close()
    local request = vim.tbl_extend('force', options().layout, {
      path = image.path,
      display_size = image.display_size,
      title = ' Formula ',
      is_valid = function()
        return current(captured)
      end,
      on_error = function(message)
        fail(captured, message)
      end,
      on_close = function()
        if state == captured then
          M.close()
        end
      end,
    })
    local view, display_err = backend.float(request)
    if state ~= captured then
      if view then
        view:close()
      end
      return
    end
    if not view then
      fail(captured, display_err)
      return
    end
    captured.view, captured.stage = view, 'ready'
  end)
end

function M.preview(request)
  if not group then
    M.setup()
  end
  request = request or {}
  local snapshot, err = selected()
  if not snapshot then
    M.close()
    return false, err
  end
  if state and current(state) and not request.reload then
    if not request.automatic then
      state.silent = request.silent == true
      if timer then
        stop_timer()
        compile(state)
      end
    end
    return true
  end
  M.close()
  local captured = vim.tbl_extend('force', snapshot, {
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    silent = request.silent == true,
    stage = 'waiting',
  })
  state, last_error = captured, nil
  if request.automatic and options().delay > 0 then
    timer = vim.defer_fn(function()
      compile(captured)
    end, options().delay)
  else
    compile(captured)
  end
  return state == captured, last_error
end

function M.refresh()
  if not enabled then
    return
  end
  M.preview({ automatic = true, silent = true })
end

function M.toggle()
  if not group then
    M.setup()
  end
  enabled = not enabled
  if enabled then
    M.refresh()
  else
    M.close()
  end
  return enabled
end

function M.info()
  return {
    enabled = enabled,
    stage = state and (state.view and state.view:status().stage or state.stage) or (last_error and 'failed' or 'idle'),
    source = state and state.source,
    path = state and state.image and state.image.path,
    window = state and state.view and state.view:status().window,
    error = last_error,
    width = state and state.image and state.image.width,
    height = state and state.image and state.image.height,
  }
end

function M.clear_cache()
  M.close()
  return require('tex-tools.formula.render').clear(options().cache)
end

function M.setup()
  M.close()
  enabled = options().enabled
  group = vim.api.nvim_create_augroup('TexToolsFormula', { clear = true })
  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter', 'WinEnter' },
    {
      group = group,
      callback = function()
        M.refresh()
      end,
    }
  )
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave', 'VimSuspend', 'ExitPre', 'VimLeavePre' }, {
    group = group,
    callback = function()
      M.close()
    end,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      M.close()
      M.refresh()
    end,
  })
  vim.schedule(M.refresh)
end

return M
