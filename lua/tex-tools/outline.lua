local ts = require('tex-tools.treesitter')
local section = require('tex-tools.section')
local M = {}
local snapshots, clock, cache_bytes = {}, 0, 0
local query

-- Retain only plain heading/include data, bounded by both file count and size.
local function remember(key, snapshot)
  if snapshots[key] then
    cache_bytes = cache_bytes - snapshots[key].bytes
  end
  clock = clock + 1
  snapshot.used = clock
  snapshots[key] = snapshot
  cache_bytes = cache_bytes + snapshot.bytes
  while vim.tbl_count(snapshots) > 128 or cache_bytes > 8 * 1024 * 1024 do
    local oldest
    for candidate, value in pairs(snapshots) do
      if not oldest or value.used < snapshots[oldest].used then
        oldest = candidate
      end
    end
    cache_bytes = cache_bytes - snapshots[oldest].bytes
    snapshots[oldest] = nil
  end
end

local function normalize(path)
  return vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
end

local function loaded(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == path then
      return bufnr
    end
  end
end

local function source(path, bufnr)
  bufnr = bufnr or loaded(path)
  local key = path == '' and ('buffer:' .. bufnr) or path
  local stamp, size
  if bufnr then
    stamp = { bufnr = bufnr, tick = vim.api.nvim_buf_get_changedtick(bufnr) }
    size = math.max(0, vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr)) - 1)
  else
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= 'file' then
      return nil, 'Could not read included file: ' .. path
    end
    if stat.size > 2 * 1024 * 1024 then
      return nil, 'Outline source exceeds 2 MiB: ' .. path
    end
    stamp = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime, ino = stat.ino, dev = stat.dev }
    size = stat.size
  end
  local cached = snapshots[key]
  if cached and vim.deep_equal(cached.stamp, stamp) then
    clock = clock + 1
    cached.used = clock
    return cached, nil, bufnr
  end
  local content
  if bufnr then
    content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  else
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      return nil, 'Could not read included file: ' .. path
    end
    content = table.concat(lines, '\n')
  end
  return { key = key, stamp = stamp, bytes = size, content = content }, nil, bufnr
end

local function allowed(node)
  while node do
    if section.blocked(node) then
      return false
    end
    local parent = node:parent()
    if parent and section.is_heading(parent) then
      -- Heading arguments may contain macros, but are not document structure.
      for _, field in ipairs({ 'command', 'text', 'toc' }) do
        local value = ts.field(parent, field)
        if value and value:id() == node:id() then
          return false
        end
      end
    end
    node = parent
  end
  return true
end

local function index(snapshot, bufnr)
  local content = snapshot.content
  local masked = section.mask_inline(content)
  local root, err
  if bufnr and masked == content then
    root, err = ts.root(bufnr)
  else
    local ok, parser = pcall(vim.treesitter.get_string_parser, masked, 'latex')
    if not ok then
      return nil, 'LaTeX Tree-sitter parser unavailable; install the latex parser first'
    end
    local parsed, trees = pcall(parser.parse, parser)
    if parsed and trees and trees[1] then
      root = trees[1]:root()
    end
  end
  if not root then
    return nil, err or 'Could not parse outline source'
  end
  query = query
    or vim.treesitter.query.parse(
      'latex',
      [[
    [(part) (chapter) (section) (subsection) (subsubsection) (paragraph) (subparagraph)] @heading
    (latex_include) @include
  ]]
    )
  local events = {}
  for id, node in query:iter_captures(root, masked) do
    if allowed(node) then
      local command = ts.field(node, 'command')
      if query.captures[id] == 'heading' then
        local title, toc = ts.field(node, 'text'), ts.field(node, 'toc')
        if command and title and not title:has_error() and not (toc and toc:has_error()) then
          local row, col = command:range()
          events[#events + 1] = {
            row = row,
            col = col,
            level = vim.fn.index(section.levels, node:type()) + 1,
            kind = node:type(),
            starred = ts.text(command, content):sub(-1) == '*',
            title = ts.text(toc or title, content):sub(2, -2):gsub('%s+', ' '),
          }
        end
      else
        local name = command and ts.text(command, content)
        if name == '\\input' or name == '\\include' then
          local include = ts.field(ts.field(node, 'path'), 'path')
          events[#events + 1] = { kind = 'include', name = include and ts.text(include, content) }
        end
      end
    end
  end
  snapshot.events, snapshot.content = events, nil
  remember(snapshot.key, snapshot)
  return snapshot
end

function M.entries(opts)
  opts = opts or {}
  local bufnr = ts.buffer(opts.bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, 'Buffer is not loaded'
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root, directory = path, path ~= '' and vim.fs.dirname(path) or vim.fn.getcwd()
  if opts.project then
    if path == '' then
      return nil, 'Open a local .tex file for a project outline'
    end
    local clients = vim.lsp.get_clients({ bufnr = bufnr, name = 'texlab' })
    local client = clients[1] or { config = { root_dir = directory } }
    local project, err = require('tex-tools.project').resolve(client, { bufnr = bufnr })
    if not project then
      return nil, err
    end
    root, directory = project.main_file, project.cwd
  end
  local result = { entries = {}, warnings = {}, root = root, project = opts.project or false }
  local active, files, bytes = {}, 0, 0
  local cursor = opts.pos
  if not cursor and bufnr == vim.api.nvim_get_current_buf() then
    local pos = vim.api.nvim_win_get_cursor(0)
    cursor = { pos[1] - 1, pos[2] }
  end
  local current, failure
  local function warn(message)
    result.warnings[#result.warnings + 1] = message
  end
  local function resolve_include(name, parent)
    if name:find('[\\#%z\r\n]') or name == '' then
      return nil
    end
    if not name:match('%.%w+$') then
      name = name .. '.tex'
    end
    if name:match('^/') or name:match('^%a:[/\\]') then
      return normalize(name)
    end
    for _, base in ipairs({ directory, vim.fs.dirname(parent) }) do
      local candidate = normalize(vim.fs.joinpath(base, name))
      if loaded(candidate) or vim.fn.filereadable(candidate) == 1 then
        return candidate
      end
    end
    return normalize(vim.fs.joinpath(directory, name))
  end
  local visit_file
  visit_file = function(file, depth, explicit_buffer)
    if failure then
      return
    end
    local key = file == '' and ('buffer:' .. bufnr) or (vim.uv.fs_realpath(file) or file)
    if active[key] then
      warn('Cyclic include skipped: ' .. file)
      return
    end
    files = files + 1
    if files > 256 or depth > 32 then
      failure = 'Outline exceeds 256 file visits or 32 nested includes'
      return
    end
    local snapshot, err, source_buffer = source(file, explicit_buffer)
    if not snapshot then
      if depth == 0 then
        failure = err
      else
        warn(err)
      end
      return
    end
    bytes = bytes + snapshot.bytes
    if bytes > 8 * 1024 * 1024 then
      failure = 'Outline sources exceed 8 MiB'
      return
    end
    if not snapshot.events then
      snapshot, err = index(snapshot, source_buffer)
      if not snapshot then
        failure = err
        return
      end
    end
    active[key] = true
    for _, event in ipairs(snapshot.events) do
      if failure then
        break
      end
      if event.kind ~= 'include' then
        local entry = vim.tbl_extend('force', event, { path = file, bufnr = source_buffer })
        result.entries[#result.entries + 1] = entry
        if file == path and cursor and (entry.row < cursor[1] or entry.row == cursor[1] and entry.col <= cursor[2]) then
          current = entry
        end
      elseif opts.project then
        local target = event.name and resolve_include(event.name, file)
        if target then
          visit_file(target, depth + 1)
        else
          warn('Nonliteral include skipped in ' .. file)
        end
      end
    end
    active[key] = nil
  end
  visit_file(root, 0, root == path and bufnr or nil)
  if failure then
    return nil, failure
  end
  if current then
    current.current = true
  end
  local query = (opts.query or ''):lower()
  if query ~= '' then
    result.entries = vim.tbl_filter(function(entry)
      return entry.title:lower():find(query, 1, true) ~= nil or entry.path:lower():find(query, 1, true) ~= nil
    end, result.entries)
  end
  return result
end

function M.open(opts)
  opts = vim.deepcopy(opts or {})
  opts.bufnr = ts.buffer(opts.bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  opts.pos = opts.pos or { cursor[1] - 1, cursor[2] }
  local snapshot, err = M.entries(opts)
  if not snapshot then
    return false, err
  end
  local origin = vim.api.nvim_get_current_win()
  vim.cmd('botright 12new')
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'tex-tools-outline'
  vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
  local first = 4
  local function draw()
    local lines = {
      'LaTeX outline: ' .. (opts.project and 'project' or 'current file'),
      '/ search  <CR> jump  q close  r refresh  f filter',
      '',
    }
    local minimum, selected = #section.levels, first
    for _, entry in ipairs(snapshot.entries) do
      minimum = math.min(minimum, entry.level)
    end
    for _, entry in ipairs(snapshot.entries) do
      local location = entry.path ~= '' and vim.fn.fnamemodify(entry.path, ':~:.') or '[No Name]'
      lines[#lines + 1] = (entry.current and '> ' or '  ')
        .. string.rep('  ', entry.level - minimum)
        .. entry.title
        .. (entry.starred and ' *' or '')
        .. '  ['
        .. location
        .. ':'
        .. (entry.row + 1)
        .. ']'
      if entry.current then
        selected = #lines
      end
    end
    if #snapshot.entries == 0 then
      lines[#lines + 1] = '(No matching sections)'
    end
    for _, warning in ipairs(snapshot.warnings) do
      lines[#lines + 1] = '! ' .. warning
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_cursor(win, { selected, 0 })
  end
  local function refresh(query)
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local options = vim.tbl_extend('force', opts, { query = query or opts.query })
    local updated, message = M.entries(options)
    if updated then
      snapshot, opts = updated, options
      draw()
    else
      vim.notify(message, vim.log.levels.WARN, { title = 'tex-tools' })
    end
  end
  vim.keymap.set('n', 'q', function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'r', function()
    refresh()
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'f', function()
    vim.ui.input({ prompt = 'Outline filter (empty clears): ', default = opts.query or '' }, function(query)
      if query ~= nil then
        refresh(query)
      end
    end)
  end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', function()
    local index = vim.api.nvim_win_get_cursor(win)[1] - first + 1
    local entry = snapshot.entries[index]
    if not entry then
      return
    end
    local target = entry.bufnr
    if not target or not vim.api.nvim_buf_is_valid(target) then
      target = vim.fn.bufadd(entry.path)
    end
    local loaded_ok = pcall(vim.fn.bufload, target)
    if not loaded_ok or not vim.api.nvim_buf_is_loaded(target) then
      vim.notify('Could not load outline target', vim.log.levels.WARN, { title = 'tex-tools' })
      return
    end
    local can_reuse = vim.api.nvim_win_is_valid(origin)
    if can_reuse then
      local original = vim.api.nvim_win_get_buf(origin)
      can_reuse = target == original or not vim.bo[original].modified or vim.o.hidden
    end
    if can_reuse then
      vim.api.nvim_set_current_win(origin)
      vim.cmd.normal({ "m'", bang = true })
      local ok, message = pcall(vim.api.nvim_win_set_buf, origin, target)
      if not ok then
        vim.notify(message, vim.log.levels.WARN, { title = 'tex-tools' })
        return
      end
      vim.api.nvim_win_close(win, true)
    else
      vim.api.nvim_win_set_buf(win, target)
    end
    local row = math.min(entry.row + 1, vim.api.nvim_buf_line_count(target))
    local line = vim.api.nvim_buf_get_lines(target, row - 1, row, false)[1]
    vim.api.nvim_win_set_cursor(0, { row, math.min(entry.col, #line) })
    vim.cmd.normal({ 'zv', bang = true })
  end, { buffer = buf, silent = true })
  draw()
  return true, buf
end

return M
