-- One controller owns LaTeX image/formula selection and formula compilation.
-- image-tools is an optional display backend, called through public float()/close().
local M = {}
local state, timer, group
local enabled, images_enabled = false, false
local last_error

local function options()
  return require('tex-tools.config').options.formula_preview
end
local function image_options()
  return require('tex-tools.config').options.image_preview
end

local function is_tex(buf)
  return vim.tbl_contains({ 'tex', 'latex', 'plaintex' }, vim.bo[buf].filetype)
end

function M.own(buf)
  local owner = vim.b[buf].image_tools_preview_owner
  if owner == nil or owner == 'tex-tools' then
    vim.b[buf].image_tools_preview_owner = is_tex(buf) and (enabled or images_enabled) and 'tex-tools' or nil
  end
end

local function selected(selection, automatic)
  local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local formula, image, err
  if selection ~= 'image' and (not automatic or enabled) then
    formula, err = require('tex-tools.formula.detect').find(buf, cursor[1] - 1, cursor[2], options())
  end
  if selection ~= 'formula' and (not automatic or images_enabled) then
    image, err = require('tex-tools.image.detect').find(buf, cursor[1] - 1, cursor[2], image_options())
  end
  if formula then
    formula.kind = 'formula'
  end
  if formula and image then
    local ts = require('tex-tools.treesitter')
    if ts.contains(image.range, cursor[1] - 1, cursor[2]) then
      return image
    end
    if ts.contains(formula.range, cursor[1] - 1, cursor[2]) then
      return formula
    end
    if
      image.range[1] < formula.range[1] or image.range[1] == formula.range[1] and image.range[2] < formula.range[2]
    then
      return image
    end
  end
  return formula or image, err
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
  local snapshot = selected(captured.selection, captured.automatic)
  return snapshot and snapshot.kind == captured.kind and snapshot.key == captured.key or false
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
  captured.stage = captured.kind == 'image' and 'preparing' or 'compiling'
  local function deliver(err, image)
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
    local request = vim.tbl_extend('force', (captured.kind == 'image' and image_options() or options()).layout, {
      path = image.path,
      display_size = image.display_size,
      title = captured.kind == 'image' and ' Image ' or ' Formula ',
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
  end
  if captured.kind == 'image' then
    deliver(nil, { path = captured.path, release = function() end })
  else
    captured.cancel = require('tex-tools.formula.render').prepare(captured.source, options(), deliver)
  end
end

function M.ensure()
  if not group then
    M.setup()
  end
  return M
end

function M.preview(request)
  if not group then
    M.setup()
  end
  request = request or {}
  local selection = request.selection or 'formula'
  local snapshot, err = selected(selection, request.automatic)
  if not snapshot then
    M.close()
    return false, err
  end
  if state and state.kind == snapshot.kind and state.key == snapshot.key and current(state) and not request.reload then
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
    selection = selection,
    automatic = request.automatic == true,
  })
  state, last_error = captured, nil
  local delay = (captured.kind == 'image' and image_options() or options()).delay
  if request.automatic and delay > 0 then
    timer = vim.defer_fn(function()
      compile(captured)
    end, delay)
  else
    compile(captured)
  end
  return state == captured, last_error
end

function M.refresh()
  M.own(vim.api.nvim_get_current_buf())
  if not enabled and not images_enabled then
    return
  end
  if not is_tex(vim.api.nvim_get_current_buf()) then
    M.close()
    return
  end
  M.preview({ automatic = true, silent = true, selection = 'all' })
end

function M.toggle()
  if not group then
    M.setup()
  end
  enabled = not enabled
  images_enabled = enabled and image_options().enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.own(buf)
  end
  if enabled or images_enabled then
    M.refresh()
  else
    M.close()
  end
  return enabled
end

function M.info()
  return {
    enabled = enabled,
    images_enabled = images_enabled,
    kind = state and state.kind,
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
  enabled, images_enabled = options().enabled, image_options().enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.own(buf)
  end
  group = vim.api.nvim_create_augroup('TexToolsFormula', { clear = true })
  vim.api.nvim_create_autocmd({
    'CursorMoved',
    'CursorMovedI',
    'TextChanged',
    'TextChangedI',
    'BufEnter',
    'WinEnter',
    'CursorHold',
    'CursorHoldI',
  }, {
    group = group,
    callback = function()
      M.refresh()
    end,
  })
  -- Rendering can set FileType inside an autocmd window. Claim source buffers
  -- immediately, but never close/reselect a view from a temporary render buffer.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(event)
      M.own(event.buf)
      if vim.bo[event.buf].buftype == '' then
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == event.buf then
            M.refresh()
          end
        end)
      end
    end,
  })
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
