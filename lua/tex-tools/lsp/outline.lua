-- Render symbols and include links supplied by texquill, without parsing TeX.
local M = {}

function M.entries(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local client, err = require('tex-tools.lsp').client(bufnr)
  if not client then
    return nil, err
  end
  local adapter = require('tex-tools.lsp.texquill')
  local uri = vim.uri_from_bufnr(bufnr)
  local root = uri
  if opts.project then
    local status
    status, err = adapter.status(client, bufnr)
    if not status then
      return nil, err
    end
    root = status.rootUri
  end
  local result = { entries = {}, warnings = {}, root = vim.uri_to_fname(root), project = opts.project or false }
  local active, visits = {}, 0
  local current, cursor = nil, opts.pos
  if not cursor and bufnr == vim.api.nvim_get_current_buf() then
    local pos = vim.api.nvim_win_get_cursor(0)
    cursor = { pos[1] - 1, pos[2] }
  end
  local function visit(target, depth)
    if active[target] then
      result.warnings[#result.warnings + 1] = 'Cyclic include skipped: ' .. vim.uri_to_fname(target)
      return true
    end
    visits = visits + 1
    if visits > 256 or depth > 32 then
      return nil, 'Outline exceeds 256 file visits or 32 nested includes'
    end
    active[target] = true
    local symbols, message =
      adapter.query(client, 'textDocument/documentSymbol', { textDocument = { uri = target } }, bufnr)
    if not symbols then
      active[target] = nil
      return nil, message
    end
    local events = {}
    local function flatten(items, level)
      for _, symbol in ipairs(items) do
        local range = symbol.selectionRange or (symbol.location or {}).range or symbol.range
        if symbol.kind == vim.lsp.protocol.SymbolKind.Namespace and range then
          local name = (symbol.detail or ''):gsub('^\\', ''):gsub('%*$', '')
          local index = vim.fn.index(require('tex-tools.section').levels, name)
          events[#events + 1] = {
            row = range.start.line,
            col = range.start.character,
            encoding = 'utf-16',
            level = index >= 0 and index + 1 or level,
            kind = name,
            title = symbol.name,
            starred = (symbol.detail or ''):sub(-1) == '*',
            path = vim.uri_to_fname(target),
            bufnr = target == uri and bufnr or nil,
          }
        end
        if symbol.children then
          flatten(symbol.children, level + 1)
        end
      end
    end
    flatten(symbols, 1)
    if opts.project then
      local links
      links, message = adapter.query(client, 'textDocument/documentLink', { textDocument = { uri = target } }, bufnr)
      if not links then
        active[target] = nil
        return nil, message
      end
      for _, link in ipairs(links) do
        if type(link.target) == 'string' and link.target:match('^file:.*%.tex$') then
          events[#events + 1] = { row = link.range.start.line, col = link.range.start.character, target = link.target }
        end
      end
    end
    table.sort(events, function(a, b)
      return a.row < b.row or a.row == b.row and a.col < b.col
    end)
    for _, event in ipairs(events) do
      if event.target then
        local ok
        ok, message = visit(event.target, depth + 1)
        if not ok then
          result.warnings[#result.warnings + 1] = message
        end
      else
        result.entries[#result.entries + 1] = event
        if target == uri and cursor then
          local line = vim.api.nvim_buf_get_lines(bufnr, event.row, event.row + 1, false)[1] or ''
          local col = vim.str_byteindex(line, 'utf-16', event.col, false)
          if event.row < cursor[1] or event.row == cursor[1] and col <= cursor[2] then
            current = event
          end
        end
      end
    end
    active[target] = nil
    return true
  end
  local ok
  ok, err = visit(root, 0)
  if not ok then
    return nil, err
  end
  if current then
    current.current = true
  end
  local query = (opts.query or ''):lower()
  result.entries = vim.tbl_filter(function(entry)
    return entry.title:lower():find(query, 1, true) ~= nil or entry.path:lower():find(query, 1, true) ~= nil
  end, result.entries)
  return result
end

return M
