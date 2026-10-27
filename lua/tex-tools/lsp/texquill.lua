-- texquill owns roots, artifact discovery, build lifecycle and SyncTeX.
-- This adapter only translates plugin actions and presents server results.
local M = {}
local attached = setmetatable({}, { __mode = 'k' })

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'tex-tools' })
end

function M.settings(client)
  local initial = (client.config or {}).init_options or {}
  local settings = client.settings or {}
  return vim.tbl_deep_extend('force', {}, initial.latex or initial, settings.latex or settings)
end

function M.configure(client, fields)
  local previous = client.settings
  local settings = vim.deepcopy(previous or {})
  -- Preserve the server's accepted wrapped or unwrapped settings shape.
  local target = settings.latex or settings
  local effective = M.settings(client)
  for key, value in pairs(effective) do
    target[key] = vim.deepcopy(value)
  end
  target.build = target.build or {}
  for key, value in pairs(fields) do
    target.build[key] = value
  end
  client.settings = settings
  local ok, accepted = pcall(client.notify, client, 'workspace/didChangeConfiguration', { settings = settings })
  if not ok or not accepted then
    client.settings = previous
    return false, ok and 'texquill rejected the configuration change' or tostring(accepted)
  end
  return true
end

function M.attach(client)
  if attached[client] then
    return
  end
  attached[client] = true
  client.handlers = client.handlers or {}
  for _, method in ipairs({ 'latex/buildStarted', 'latex/buildFinished' }) do
    local previous = client.handlers[method] or vim.lsp.handlers[method]
    client.handlers[method] = function(err, result, ctx, config)
      if not err and type(result) == 'table' then
        local state = require('tex-tools.build').state(client)
        if method == 'latex/buildStarted' then
          state.output_lines = {}
          require('tex-tools.build_output').changed(state)
        else
          if type(result.output) == 'string' then
            require('tex-tools.build_output').append(state, result.output)
          end
          if not previous then
            notify(
              result.message or ('Build: ' .. tostring(result.status)),
              result.status == 'success' and vim.log.levels.INFO or vim.log.levels.WARN
            )
          end
        end
      end
      if previous then
        return previous(err, result, ctx, config)
      end
    end
  end
  local main = require('tex-tools.config').options.build.main_file
  if main then
    local ok, err = M.configure(client, { rootFile = main })
    if not ok then
      notify(err, vim.log.levels.WARN)
    end
  end
end

local function document(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' or file:match('^%w+://') then
    return nil, 'Save this buffer to a local .tex file first'
  end
  return vim.uri_from_bufnr(bufnr)
end

local function execute(command, argument, callback)
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  local uri
  uri, err = document()
  if not uri then
    return false, err
  end
  return require('tex-tools.lsp').execute(client, command, { argument or uri }, callback)
end

-- Synchronous public snapshot APIs query the server rather than reconstructing
-- roots or maintaining a second state machine. Compilation remains async.
function M.query(client, method, params, bufnr)
  local response, err = client:request_sync(method, params, 2000, bufnr or vim.api.nvim_get_current_buf())
  if not response then
    return nil, tostring(err or 'texquill request timed out')
  end
  if response.err then
    return nil, response.err.message or tostring(response.err)
  end
  if response.result == nil or response.result == vim.NIL then
    return nil, 'texquill returned no result for ' .. method
  end
  return response.result
end

function M.status(client, bufnr)
  local uri, err = document(bufnr)
  if not uri then
    return nil, err
  end
  return M.query(client, 'workspace/executeCommand', { command = 'latex.buildStatus', arguments = { uri } }, bufnr)
end

function M.build()
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  local uri
  uri, err = document()
  if not uri then
    return false, err
  end
  local modified = vim.bo.modified
  if modified then
    local ok, save_err = pcall(vim.cmd.update)
    if not ok then
      return false, tostring(save_err)
    end
  end
  -- The server coalesces running builds. Do not infer effective onSave from
  -- client defaults: project configuration can override it.
  return require('tex-tools.lsp').execute(client, 'latex.build', { uri })
end

function M.cancel_build()
  return execute('latex.cancelBuild')
end

function M.cancel_all_builds()
  local clients = require('tex-tools.lsp').clients()
  if #clients == 0 then
    return false, 'No texquill clients are running'
  end
  local failures = {}
  for _, client in ipairs(clients) do
    local ok, err = require('tex-tools.lsp').execute(client, 'latex.cancelBuild', {})
    if not ok then
      failures[#failures + 1] = err
    end
  end
  return #failures == 0, #failures > 0 and table.concat(failures, '\n') or nil
end

function M.build_status()
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return nil, err
  end
  local result
  result, err = M.status(client)
  if not result then
    return nil, err
  end
  local snapshot = vim.deepcopy(result)
  snapshot.client_id, snapshot.phase, snapshot.uri = client.id, result.status, result.rootUri
  snapshot.compiler = result.executable or (M.settings(client).build or {}).executable or 'latexmk'
  snapshot.on_save = (M.settings(client).build or {}).onSave == true
  if type(result.durationMs) == 'number' then
    snapshot.elapsed = result.durationMs / 1000
  end
  return snapshot
end

function M.show_build_status()
  local result, err = M.build_status()
  if not result then
    return false, err
  end
  notify(vim.inspect(result))
  return true
end

function M.build_on_save(enabled)
  vim.validate('enabled', enabled, 'boolean', true)
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  if enabled == nil then
    enabled = not ((M.settings(client).build or {}).onSave == true)
  end
  local ok
  ok, err = M.configure(client, { onSave = enabled })
  if not ok then
    return false, err
  end
  return true, enabled
end

function M.clean(full)
  return execute(full and 'latex.cleanArtifacts' or 'latex.cleanAuxiliary', nil, function(err, result)
    if err then
      notify(err.message or tostring(err), vim.log.levels.ERROR)
    elseif type(result) == 'table' then
      local errors = type(result.errors) == 'table' and #result.errors or 0
      notify(
        errors > 0 and vim.inspect(result.errors) or 'Build artifacts cleaned',
        errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end
  end)
end

local pending_forward = {}

function M.forward_search()
  local bufnr = vim.api.nvim_get_current_buf()
  local uri, err = document(bufnr)
  if not uri then
    return false, err
  end
  -- Capture the source position now, even if LspAttach has not happened yet.
  local params = vim.lsp.util.make_position_params(0, 'utf-16')
  local position = { uri = uri, position = params.position }
  local lsp = require('tex-tools.lsp')
  local function ready_client()
    for _, client in ipairs(lsp.clients(bufnr)) do
      if client.initialized then
        return client
      end
    end
  end
  local function send(client, target)
    M.attach(client)
    return lsp.execute(client, 'latex.forwardSearch', { target }, function(error, result)
      if error then
        notify(error.message or tostring(error), vim.log.levels.ERROR)
        return
      end
      local ok, message = require('tex-tools.viewer').show_location(client, result, target)
      if not ok then
        notify(message, vim.log.levels.WARN)
      end
    end, bufnr)
  end
  local client = ready_client()
  if client then
    if pending_forward[bufnr] then
      pending_forward[bufnr].cancel()
    end
    return send(client, position)
  end
  if pending_forward[bufnr] then
    pending_forward[bufnr].position = position
    return true
  end
  local request = { position = position }
  pending_forward[bufnr] = request
  request.cancel = function()
    pending_forward[bufnr] = nil
    vim.api.nvim_del_autocmd(request.autocmd)
  end
  request.autocmd = vim.api.nvim_create_autocmd({ 'LspAttach', 'BufWipeout' }, {
    buffer = bufnr,
    callback = function(event)
      if event.event == 'BufWipeout' or lsp.backend() ~= 'texquill' then
        request.cancel()
        return
      end
      local attached_client = ready_client()
      if attached_client then
        request.cancel()
        local ok, message = send(attached_client, request.position)
        if not ok then
          notify(message, vim.log.levels.ERROR)
        end
      end
    end,
  })
  vim.defer_fn(function()
    if pending_forward[bufnr] == request then
      request.cancel()
      notify('texquill did not attach; forward search was cancelled', vim.log.levels.WARN)
    end
  end, 10000)
  return true
end

function M.inverse_search(page, x, y, context)
  if
    type(page) ~= 'number'
    or page < 1
    or page >= math.huge
    or page % 1 ~= 0
    or type(x) ~= 'number'
    or not (x >= 0 and x < math.huge)
    or type(y) ~= 'number'
    or not (y >= 0 and y < math.huge)
  then
    return false, 'Use a positive integer page and finite nonnegative PDF coordinates'
  end
  local revision
  if context then
    context.inverse_revision = (context.inverse_revision or 0) + 1
    revision = context.inverse_revision
  end
  local function same_uri(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then
      return false
    end
    local function canonical(uri)
      local file = vim.uri_to_fname(uri)
      return vim.uv.fs_realpath(file) or vim.fs.normalize(file)
    end
    return canonical(a) == canonical(b)
  end
  local function callback(err, result)
    if
      context
      and (
        context.cancelled
        or context.inverse_revision ~= revision
        or not vim.api.nvim_buf_is_loaded(context.bufnr)
        or vim.uri_from_bufnr(context.bufnr) ~= context.source_uri
        or (context.client.is_stopped and context.client:is_stopped())
      )
    then
      return
    end
    if err then
      notify(err.message or tostring(err), vim.log.levels.ERROR)
    elseif
      context
      and (
        type(result) ~= 'table'
        or not same_uri(result.pdfUri, context.pdf_uri)
        or not same_uri(result.rootUri, context.uri)
      )
    then
      notify('Folio reverse-search result belongs to a different PDF/project', vim.log.levels.WARN)
    elseif type(result) == 'table' and result.locations and result.locations[1] then
      vim.lsp.util.show_document(result.locations[1], 'utf-16', { focus = true })
    else
      notify('No source location returned by texquill', vim.log.levels.WARN)
    end
  end
  local argument = { uri = context and context.uri or vim.uri_from_bufnr(0), page = page, x = x, y = y }
  if context then
    return require('tex-tools.lsp').execute(
      context.client,
      'latex.inverseSearch',
      { argument },
      callback,
      context.bufnr
    )
  end
  return execute('latex.inverseSearch', argument, callback)
end

function M.project_info(client, bufnr)
  local result, err = M.status(client, bufnr)
  if not result then
    return nil, err
  end
  if type(result.rootUri) ~= 'string' then
    return nil, 'texquill returned no project root'
  end
  local function path(uri)
    return type(uri) == 'string' and vim.uri_to_fname(uri) or nil
  end
  local main, pdf, log = path(result.rootUri), path(result.pdfUri), path(result.logUri)
  return {
    client_id = client.id,
    root_dir = (client.config or {}).root_dir,
    main_file = main,
    main_source = 'texquill',
    cwd = vim.fs.dirname(main),
    compiler = result.executable or (M.settings(client).build or {}).executable or 'latexmk',
    build = vim.deepcopy(M.settings(client).build or {}),
    pdf_file = pdf,
    pdf_dir = pdf and vim.fs.dirname(pdf),
    pdf_name = pdf and vim.fs.basename(pdf),
    log_file = log,
    log_dir = log and vim.fs.dirname(log),
    artifact_source = 'texquill',
    status = result.status,
  }
end

function M.main_file(client, path)
  if path ~= nil then
    if path ~= false and (type(path) ~= 'string' or path == '' or path:find('%z')) then
      return false, 'Provide a nonempty .tex path'
    end
    local ok, err = M.configure(client, { rootFile = path == false and vim.NIL or path })
    if not ok then
      return false, err
    end
  end
  local info, err = M.project_info(client)
  return info ~= nil, info and info.main_file or err
end

function M.compiler_snapshot(client)
  local build = M.settings(client).build or {}
  local names = require('tex-tools.compiler').names()
  local selected
  for _, name in ipairs(names) do
    local matches = true
    local profile = require('tex-tools.config').options.build.profiles[name]
    for _, field in ipairs(require('tex-tools.config').profile_fields) do
      local value = build[field]
      if value == vim.NIL then
        value = nil
      end
      matches = matches and vim.deep_equal(value, profile[field])
    end
    if matches then
      selected = name
      break
    end
  end
  return {
    profile = selected,
    executable = build.executable or 'latexmk',
    args = vim.deepcopy(build.arguments),
    profiles = names,
  }
end

function M.compiler(client, name)
  if name == nil then
    return true, M.compiler_snapshot(client)
  end
  local names = require('tex-tools.compiler').names()
  if #names == 0 then
    return false, 'No compiler profiles configured; set build.profiles in setup()'
  end
  if name == 'toggle' then
    local current = M.compiler_snapshot(client).profile
    name = names[(vim.fn.index(names, current) + 1) % #names + 1]
  end
  local profile = require('tex-tools.config').options.build.profiles[name]
  if not profile then
    return false, 'Unknown compiler profile: ' .. name
  end
  local fields = {}
  for _, field in ipairs(require('tex-tools.config').profile_fields) do
    fields[field] = profile[field] == nil and vim.NIL or vim.deepcopy(profile[field])
  end
  local ok, err = M.configure(client, fields)
  if not ok then
    return false, err
  end
  return true, M.compiler_snapshot(client)
end

return M
