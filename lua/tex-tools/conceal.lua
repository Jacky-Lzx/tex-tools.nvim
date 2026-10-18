-- Window-local, ephemeral decorations: no buffer edits or syntax/query overrides.
local ts = require('tex-tools.treesitter')
local context = require('tex-tools.context')
local M = {}
local namespace = vim.api.nvim_create_namespace('tex-tools.conceal')
local buffers, windows, pending = {}, {}, {}
local registered = false

local styles = {}
for name in
  (
    'emph textbf textit textsl textsc textsf textrm texttt textup textnormal '
    .. 'bm mathbf mathit mathbfit mathsf mathrm mathtt mathnormal boldsymbol text intertext shortintertext mbox fbox'
  ):gmatch('%S+')
do
  styles[name] = true
end
local ligatures = {
  ae = 'æ',
  AE = 'Æ',
  oe = 'œ',
  OE = 'Œ',
  aa = 'å',
  AA = 'Å',
  o = 'ø',
  O = 'Ø',
  ss = 'ß',
  SS = 'ẞ',
  l = 'ł',
  L = 'Ł',
  i = 'ı',
  j = 'ȷ',
  dj = 'đ',
  DJ = 'Đ',
  lq = '‘',
  rq = '’',
}
local text_ligatures = {
  { '---', '—' },
  { '--', '–' },
  { '``', '“' },
  { "''", '”' },
  { ',,', '„' },
  { '!`', '¡' },
  { '?`', '¿' },
  { '`', '‘' },
  { "'", '’' },
}
local fancy = { dots = '…', ldots = '…', textellipsis = '…', colon = ':', slash = '/', ['_'] = '_', item = '○' }
local delimiters = {
  langle = '⟨',
  rangle = '⟩',
  lbrace = '{',
  rbrace = '}',
  ['{'] = '{',
  ['}'] = '}',
  lvert = '|',
  rvert = '|',
  vert = '|',
  lVert = '‖',
  rVert = '‖',
  Vert = '‖',
  ['|'] = '‖',
  lceil = '⌈',
  rceil = '⌉',
  lfloor = '⌊',
  rfloor = '⌋',
}
local sizes = { left = true, right = true, middle = true }
for _, size in ipairs({ 'big', 'Big', 'bigg', 'Bigg' }) do
  for _, suffix in ipairs({ '', 'l', 'r', 'm' }) do
    sizes[size .. suffix] = true
  end
end
local spaces = {
  [','] = '',
  [';'] = '',
  [':'] = '',
  ['!'] = '',
  ['>'] = '',
  [' '] = ' ',
  quad = '',
  qquad = '',
  enspace = '',
  thinspace = '',
  negthinspace = '',
  medspace = '',
  thickspace = '',
  enskip = '',
  hfill = '',
  vfill = '',
  space = ' ',
  nobreakspace = ' ',
  smallskip = '',
  medskip = '',
  bigskip = '',
}
local space_arguments = { hspace = true, vspace = true, hphantom = true, vphantom = true, phantom = true }
local unsafe_commands = {
  verb = true,
  lstinline = true,
  mintinline = true,
  url = true,
  path = true,
  nolinkurl = true,
  href = true,
  detokenize = true,
  csname = true,
}
local protected_types = {
  begin = true,
  ['end'] = true,
  label_reference = true,
  label_reference_range = true,
  acronym_reference = true,
  glossary_entry_reference = true,
  curly_group_label = true,
  curly_group_label_list = true,
  curly_group_path = true,
  curly_group_path_list = true,
  curly_group_uri = true,
  curly_group_key_value = true,
  brack_group_key_value = true,
  brack_group_argc = true,
  curly_group_command_name = true,
  curly_group_impl = true,
  uri = true,
  path = true,
  source_code = true,
  ERROR = true,
}

local function command_name(node, bufnr)
  local command = ts.field(node, 'command')
  return command and ts.text(command, bufnr):sub(2):gsub('%*$', '')
end

local function inspect(root, bufnr, row, col)
  local node = root:descendant_for_range(row, col, row, col + 1)
  local info = { math = nil, containers = {} }
  while node do
    local kind = node:type()
    local sr, sc = node:range()
    local at_start = sr == row and sc == col
    if ts.comment_types[kind] or ts.literal_types[kind] or kind:match('_definition$') then
      info.blocked = true
    elseif protected_types[kind] then
      info.blocked = true
    elseif (kind == 'generic_command' or kind == 'math_delimiter') and node:has_error() then
      info.blocked = true
    end
    -- Upstream latex parses a primitive \def's body as a sibling, rather
    -- than a field of old_command_definition (unlike \newcommand).
    if kind == 'curly_group' then
      local previous = node:prev_named_sibling()
      if previous and previous:type() == 'text' then
        previous = previous:prev_named_sibling()
      end
      if previous and previous:type() == 'old_command_definition' then
        info.blocked = true
      end
    end
    if kind == 'generic_command' then
      info.containers[#info.containers + 1] = node
      if unsafe_commands[command_name(node, bufnr)] then
        info.blocked = true
      end
    elseif kind == 'text_mode' then
      info.containers[#info.containers + 1] = node
      if info.math == nil then
        info.math = false
      end
    elseif kind == 'citation' then
      info.containers[#info.containers + 1] = node
      info.key = not at_start
    end
    if kind == 'inline_formula' or kind == 'displayed_equation' then
      info.formula = info.formula or node
      if info.math == nil then
        info.math = true
      end
    elseif info.math == nil and context.is_math_environment(node, bufnr) then
      info.math = true
    end
    node = node:parent()
  end
  return info
end

-- Only visible source lines are scanned. Descendant lookups avoid traversing
-- every sibling of large source_file/text nodes. Cached results contain no TSNodes.
local function collect(bufnr, root, top, bottom, options)
  local accents = options.accents and require('tex-tools.conceal_accents') or {}
  local marks, occupied, processed, containers = {}, {}, {}, {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, top, bottom, false)
  local function add(sr, sc, er, ec, replacement)
    for row = math.max(sr, top), math.min(er, bottom - 1) do
      local first = row == sr and sc or 0
      local last = row == er and ec or #lines[row - top + 1]
      if first < last then
        occupied[row] = occupied[row] or {}
        local overlaps = false
        for _, span in ipairs(occupied[row]) do
          if first < span[2] and last > span[1] then
            overlaps = true
            break
          end
        end
        if not overlaps then
          occupied[row][#occupied[row] + 1] = { first, last }
          marks[#marks + 1] = { row, first, last, row == sr and replacement or '' }
        end
      end
    end
  end
  local function group_edges(command, name)
    local groups = command:field(name)
    if #groups ~= 1 or groups[1]:has_error() then
      return
    end
    local group = groups[1]
    local sr, sc, er, ec = group:range()
    local first, last = group:child(0), group:child(group:child_count() - 1)
    if not first or not last or ts.text(first, bufnr) ~= '{' or ts.text(last, bufnr) ~= '}' then
      return
    end
    return sr, sc, er, ec
  end
  local function formula_bounds(formula)
    if processed[formula:id()] or formula:has_error() then
      return
    end
    processed[formula:id()] = true
    local first, last = formula:child(0), formula:child(formula:child_count() - 1)
    if not first or not last or first:id() == last:id() then
      return
    end
    local opening, closing = ts.text(first, bufnr), ts.text(last, bufnr)
    if ({ ['$'] = '$', ['$$'] = '$$', ['\\('] = '\\)', ['\\['] = '\\]' })[opening] == closing then
      local sr, sc, er, ec = first:range()
      add(sr, sc, er, ec, '')
      sr, sc, er, ec = last:range()
      add(sr, sc, er, ec, '')
    end
  end

  local function decorate_containers(info)
    if info.blocked then
      return
    end
    for _, node in ipairs(info.containers) do
      if not containers[node:id()] then
        containers[node:id()] = true
        local kind = node:type()
        local bare = command_name(node, bufnr)
        local cr, cc = node:range()
        if kind == 'citation' and options.cites and not node:has_error() then
          local sr, sc, er, ec = group_edges(node, 'keys')
          if sr then
            -- Some parsers expose the citation command as an anonymous field.
            bare = bare or ts.text(node:child(0), bufnr):sub(2):gsub('%*$', '')
            local parens = bare == 'citep' or bare == 'parencite' or bare == 'autocite'
            add(cr, cc, sr, sc, '')
            add(sr, sc, sr, sc + 1, parens and '(' or '[')
            add(er, ec - 1, er, ec, parens and ')' or ']')
          end
        elseif options.styles and styles[bare] then
          local field = kind == 'text_mode' and 'content' or 'arg'
          local sr, sc, er, ec = group_edges(node, field)
          if sr then
            add(cr, cc, sr, sc + 1, '')
            add(er, ec - 1, er, ec, '')
          end
        elseif options.spacing and space_arguments[bare] and group_edges(node, 'arg') then
          local sr, sc, er, ec = node:range()
          add(sr, sc, er, ec, '')
        end
      end
    end
  end

  for index, line in ipairs(lines) do
    local row, i = top + index - 1, 1
    if #line > 0 then
      decorate_containers(inspect(root, bufnr, row, 0))
    end
    while i <= #line do
      local char = line:sub(i, i)
      local name, length
      if char == '\\' then
        name = line:sub(i + 1):match('^([a-zA-Z@]+%*?)') or line:sub(i + 1, i + 1)
        length = #name + 1
      end
      -- Inline verbatim is not a distinct node in all latex parser versions.
      if name and (name:match('^verb%*?$') or name:match('^lstinline%*?$') or name == 'mintinline') then
        local start = i + length
        if not name:match('^verb') then
          local prefix = line:sub(start):match('^%s*%b[]%s*') or line:sub(start):match('^%s*')
          start = start + #prefix
          if name == 'mintinline' then
            local language = line:sub(start):match('^%b{}%s*')
            start = language and start + #language or #line + 1
          end
        end
        local delimiter = line:sub(start, start)
        local group = not name:match('^verb') and line:sub(start):match('^%b{}')
        local finish = group and start + #group - 1 or (delimiter ~= '' and line:find(delimiter, start + 1, true))
        i = finish and finish + 1 or #line + 1
      else
        local candidate = name or char == '$' or char == '~' or (options.ligatures and char:match("[-`',!?]"))
        if candidate then
          local info = inspect(root, bufnr, row, i - 1)
          decorate_containers(info)
          if not info.blocked and not info.key then
            if options.math_bounds and info.formula then
              formula_bounds(info.formula)
            end
            if name then
              local bare = name:gsub('%*$', '')
              local tail, replacement, consumed = line:sub(i + length), nil, length
              if options.accents and accents[bare] and not info.math then
                local argument = tail:match('^%s*{([A-Za-z])}') or tail:match('^%s*([A-Za-z])')
                if argument and accents[bare][argument] then
                  local matched = tail:match('^%s*{[A-Za-z]}') or tail:match('^%s*[A-Za-z]')
                  replacement, consumed = accents[bare][argument], length + #matched
                end
              elseif options.ligatures and ligatures[bare] and not info.math then
                replacement = ligatures[bare]
                if tail:sub(1, 2) == '{}' then
                  consumed = consumed + 2
                end
              elseif options.math_delimiters and info.math and sizes[bare] then
                local whitespace = tail:match('^%s*')
                local marker = tail:sub(#whitespace + 1)
                local control = marker:match('^\\([A-Za-z]+)') or marker:match('^\\(.)')
                if marker:match('^[%(%)[%]|.<>]') or delimiters[control] then
                  replacement = ''
                  if marker:sub(1, 1) == '.' then
                    consumed = consumed + #whitespace + 1
                  end
                end
              elseif options.math_delimiters and info.math and delimiters[bare] then
                replacement = delimiters[bare]
              elseif options.spacing and spaces[bare] ~= nil then
                replacement = spaces[bare]
              elseif options.fancy and fancy[bare] then
                replacement = fancy[bare]
              end
              if replacement ~= nil then
                add(row, i - 1, row, i - 1 + consumed, replacement)
                length = consumed
              end
            elseif options.spacing and char == '~' then
              add(row, i - 1, row, i, ' ')
            elseif options.ligatures and not info.math then
              for _, pair in ipairs(text_ligatures) do
                if line:sub(i, i + #pair[1] - 1) == pair[1] then
                  add(row, i - 1, row, i - 1 + #pair[1], pair[2])
                  length = #pair[1]
                  break
                end
              end
            end
          end
        end
        i = i + (length or 1)
      end
    end
  end
  return marks
end

local function render(_, winid, bufnr, top, bottom)
  local options = buffers[bufnr]
  if
    not options
    or vim.wo[winid].conceallevel == 0
    or not vim.tbl_contains({ 'tex', 'plaintex' }, vim.bo[bufnr].filetype)
  then
    return false
  end
  -- on_win may report the last visible row (including row 0 in a one-line
  -- buffer); include it and clamp the exclusive bound used by get_lines.
  bottom = math.min(bottom + 1, vim.api.nvim_buf_line_count(bufnr))
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = windows[winid]
  if
    not cached
    or cached.bufnr ~= bufnr
    or cached.tick ~= tick
    or cached.top ~= top
    or cached.bottom ~= bottom
    or cached.options ~= options
  then
    if pending[bufnr] then
      return false
    end
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'latex')
    if not ok or not parser then
      return false
    end
    local request, synchronous = {}, true
    pending[bufnr] = request
    -- Neovim yields expensive cold/incremental parses instead of blocking a
    -- redraw. Until completion the source remains visible; reuse warm trees.
    local parsed, trees = pcall(parser.parse, parser, nil, function(err, result)
      if pending[bufnr] ~= request then
        return
      end
      pending[bufnr] = nil
      if not synchronous and not err and result and result[1] then
        vim.schedule(function()
          if buffers[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) then
            vim.cmd.redraw({ bang = true })
          end
        end)
      end
    end)
    synchronous = false
    if not parsed then
      pending[bufnr] = nil
    end
    if not parsed or not trees or not trees[1] then
      return false
    end
    cached = {
      bufnr = bufnr,
      tick = tick,
      top = top,
      bottom = bottom,
      options = options,
      marks = collect(bufnr, trees[1]:root(), top, bottom, options),
    }
    windows[winid] = cached
  end
  for _, mark in ipairs(cached.marks) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, mark[1], mark[2], {
      end_col = mark[3],
      conceal = mark[4],
      ephemeral = true,
      priority = 110,
    })
  end
  return false
end

function M.attach(bufnr, options)
  buffers[bufnr] = options or nil
  windows = {}
  if options and not registered then
    registered = true
    vim.api.nvim_set_decoration_provider(namespace, { on_win = render })
    local group = vim.api.nvim_create_augroup('TexToolsConceal', { clear = true })
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = group,
      callback = function(event)
        buffers[event.buf] = nil
        pending[event.buf] = nil
        windows = {}
      end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
      group = group,
      callback = function(event)
        windows[tonumber(event.match)] = nil
      end,
    })
  end
end

return M
