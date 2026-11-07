-- Conservative fallback for snippet predicates when Tree-sitter is unavailable.
local M = {}
function M.inspect(opts)
  opts = opts or {}
  local buf = opts.bufnr
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return nil, 'Buffer is not loaded'
  end
  local pos = opts.pos
  if not pos then
    if buf ~= vim.api.nvim_get_current_buf() then
      return nil, 'Provide pos for a non-current buffer'
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    pos = { cursor[1] - 1, cursor[2] }
  end
  if pos[1] < 0 or pos[1] >= vim.api.nvim_buf_line_count(buf) or pos[2] < 0 then
    return nil, 'Position is outside the buffer'
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, pos[1] + 1, false)
  lines[#lines] = lines[#lines]:sub(1, pos[2])
  local source = table.concat(lines, '\n')
  local frames, envs, depth, cursor, literal = {}, {}, 0, 1, nil
  local math_envs = {}
  for name in
    ('math displaymath equation eqnarray align aligned alignedat alignat flalign gather gathered multline split'):gmatch(
      '%S+'
    )
  do
    math_envs[name] = true
  end
  for _, name in ipairs(require('tex-tools.config').options.math_environments) do
    math_envs[name:gsub('%*$', '')] = true
  end
  local function push(kind, mode, close)
    frames[#frames + 1] = { kind = kind, mode = mode, close = close }
  end
  local function close(marker)
    for index = #frames, 1, -1 do
      if frames[index].close == marker then
        for i = #frames, index, -1 do
          frames[i] = nil
        end
        return
      end
    end
  end
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if literal then
      local ending = '\\end{' .. literal .. '}'
      local at = source:find(ending, cursor, true)
      if not at then
        break
      end
      close('env:' .. literal)
      envs[literal], literal, cursor = nil, nil, at + #ending
    elseif char == '%' then
      local newline = source:find('\n', cursor, true)
      if not newline then
        return { math = false, environments = {} }
      end
      cursor = newline + 1
    elseif char == '\\' then
      local command = source:sub(cursor):match('^\\([%a]+)')
      local marker = source:sub(cursor, cursor + 1)
      local env, finish
      if command == 'begin' or command == 'end' then
        local tail = source:sub(cursor)
        local _, stop, name = tail:find('^\\' .. command .. '%s*{([^}]+)}')
        env, finish = name, stop
      end
      if env then
        if command == 'begin' then
          envs[env] = (envs[env] or 0) + 1
          local is_literal = vim.tbl_contains({ 'verbatim', 'verbatim*', 'lstlisting', 'minted', 'comment' }, env)
          if is_literal then
            literal = env
            push('literal', false, 'env:' .. env)
          elseif math_envs[env:gsub('%*$', '')] then
            push('math', true, 'env:' .. env)
          end
        else
          envs[env] = math.max(0, (envs[env] or 0) - 1)
          close('env:' .. env)
        end
        cursor = cursor + finish
      elseif marker == '\\(' or marker == '\\[' then
        push('math', true, marker == '\\(' and '\\)' or '\\]')
        cursor = cursor + 2
      elseif marker == '\\)' or marker == '\\]' then
        close(marker)
        cursor = cursor + 2
      elseif command == 'text' then
        local _, stop = source:sub(cursor):find('^\\text%s*{')
        if stop then
          depth = depth + 1
          push('text', false, depth)
          cursor = cursor + stop
        else
          cursor = cursor + #command + 1
        end
      else
        cursor = cursor + (command and #command + 1 or 2)
      end
    elseif char == '$' then
      local marker = source:sub(cursor, cursor + 1) == '$$' and '$$' or '$'
      if frames[#frames] and frames[#frames].close == marker then
        close(marker)
      else
        push('math', true, marker)
      end
      cursor = cursor + #marker
    elseif char == '{' then
      depth, cursor = depth + 1, cursor + 1
    elseif char == '}' then
      close(depth)
      depth, cursor = math.max(0, depth - 1), cursor + 1
    else
      cursor = cursor + 1
    end
  end
  return {
    math = not literal and frames[#frames] ~= nil and frames[#frames].mode or false,
    environments = literal and {} or envs,
  }
end
return M
