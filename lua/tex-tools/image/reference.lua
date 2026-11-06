-- Module: tex-tools.image.reference
--
-- Purpose:
--   Decode bounded literal includegraphics commands and their original buffer
--   ranges.
--
-- Architecture:
--   Used for bounded literal decoding at Tree-sitter-owned command positions. Exclude
--   comments/inline verbatim, decode literal paths and locate covering commands
--   within line/byte scan budgets.
--
-- Ownership:
--   Keep no state; the preview detector owns syntax snapshots. Preserve byte columns and row coordinates; filename
--   contents must stay on one line.

local M = {}
local defaults = { latex = { max_reference_lines = 64, max_reference_bytes = 16 * 1024 }, max_scan_lines = 10000 }
local VERB_COMMAND = '\\verb'
local DETOKENIZE_COMMAND = '\\detokenize'
local INCLUDEGRAPHICS_COMMAND = '\\includegraphics'
-- Test an odd backslash run before a syntax byte.
---@param line string Source text.
---@param pos integer One-based byte position.
---@return boolean escaped
local function escaped(line, pos)
  local count = 0
  while pos > 1 and line:sub(pos - 1, pos - 1) == '\\' do
    count, pos = count + 1, pos - 1
  end
  return count % 2 == 1
end

-- Find a balanced group, respecting escapes and brace nesting inside option brackets.
---@param line string Source text, possibly multiline.
---@param pos integer One-based opening position.
---@param opening string Opening delimiter.
---@param ending string Closing delimiter.
---@return integer? finish One-based closing position.
local function group(line, pos, opening, ending)
  if line:sub(pos, pos) ~= opening then
    return
  end
  local depth, braces = 1, 0
  for i = pos + 1, #line do
    local char = line:sub(i, i)
    if not escaped(line, i) then
      if opening == '[' and char == '{' then
        braces = braces + 1
      elseif opening == '[' and char == '}' then
        braces = math.max(0, braces - 1)
      elseif char == opening and braces == 0 then
        depth = depth + 1
      elseif char == ending and braces == 0 then
        depth = depth - 1
        if depth == 0 then
          return i
        end
      end
    end
  end
end

-- Advance over whitespace without changing source offsets.
---@param line string Source text.
---@param pos integer One-based current byte.
---@return integer position First non-whitespace byte or end plus one.
local function space(line, pos)
  while line:sub(pos, pos):match('%s') do
    pos = pos + 1
  end
  return pos
end

-- Strip a line comment and replace inline verbatim segments with equal-length spaces.
---@param line string One source line.
---@return string cleaned Comments shorten the result; sanitize restores its byte length.
local function clean(line)
  local pos = 1
  while pos <= #line do
    if not escaped(line, pos) and line:sub(pos, pos) == '%' then
      return line:sub(1, pos - 1)
    end
    local after_verb = pos + #VERB_COMMAND
    if
      not escaped(line, pos)
      and line:sub(pos, after_verb - 1) == VERB_COMMAND
      and not line:sub(after_verb, after_verb):match('%a')
    then
      local delimiter = after_verb
      if line:sub(delimiter, delimiter) == '*' then
        delimiter = delimiter + 1
      end
      local finish = line:find(line:sub(delimiter, delimiter), delimiter + 1, true)
      if not finish then
        return line:sub(1, pos - 1)
      end
      line = line:sub(1, pos - 1) .. string.rep(' ', finish - pos + 1) .. line:sub(finish + 1)
      pos = finish + 1
    else
      pos = pos + 1
    end
  end
  return line
end

-- Decode supported TeX escapes or one complete detokenize wrapper; refuse unresolved macros.
---@param src string Argument contents.
---@return string? source
local function literal(src)
  src = vim.trim(src)
  local first = src:find(DETOKENIZE_COMMAND, 1, true)
  if first == 1 then
    local start = space(src, #DETOKENIZE_COMMAND + 1)
    local finish = group(src, start, '{', '}')
    if finish and vim.trim(src:sub(finish + 1)) == '' then
      return src:sub(start + 1, finish - 1)
    end
    return nil
  end
  src = src:gsub('\\([#$%%&_{} ])', '%1')
  if src:find('\\', 1, true) then
    return nil
  end -- Macros are not expanded.
  return src
end
M.clean, M.group, M.space, M.literal, M.escaped = clean, group, space, literal, escaped

-- Read per-reference budgets with defaults for partial/internal callers.
---@param opts? table Optional latex settings.
---@return integer max_lines
---@return integer max_bytes
function M.limits(opts)
  local config = opts and opts.latex or {}
  return config.max_reference_lines or defaults.latex.max_reference_lines,
    config.max_reference_bytes or defaults.latex.max_reference_bytes
end

-- Convert a one-based text byte offset to original row/zero-based byte-column coordinates.
---@param text string Joined source text.
---@param offset integer One-based byte position, including end plus one.
---@param first integer One-based first buffer row represented by text.
---@return integer row
---@return integer column
local function position(text, offset, first)
  local row, start = first, 1
  for ending in text:gmatch('()\n') do
    if ending >= offset then
      break
    end
    row, start = row + 1, ending + 1
  end
  return row, offset - start
end

-- Keep offsets intact when excluding comments and inline verbatim text.
-- Preserve original offsets while excluding line comments and inline verbatim text.
---@param text string One or more joined source lines.
---@return string cleaned Same byte length as the input.
local function sanitize(text)
  local lines = vim.split(text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    local cleaned = clean(line)
    lines[i] = cleaned .. string.rep(' ', #line - #cleaned)
  end
  return table.concat(lines, '\n')
end

-- Decode complete literal commands within budgets; reject split filenames without guessing dynamic
-- paths.
---@param text string Source segment.
---@param first? integer One-based first represented row; defaults to one.
---@param opts? table Optional reference budgets.
---@param anchored? boolean Stop after the first command when decoding an indexed location.
---@return TexToolsImageReference[] references
---@return string? error Limit/split-filename diagnostic; valid later references may still be returned.
---@return integer? consumed Exclusive end byte of the last complete command, including rejected arguments.
function M.parse(text, first, opts, anchored)
  first = first or 1
  text = sanitize(text)
  local max_lines, max_bytes = M.limits(opts)
  local results, pos, error_message, consumed = {}, 1, nil, nil
  while pos <= #text do
    local start = text:find(INCLUDEGRAPHICS_COMMAND, pos, true)
    if not start then
      break
    end
    pos = start + #INCLUDEGRAPHICS_COMMAND
    if not escaped(text, start) and not text:sub(pos, pos):match('%a') then
      if text:sub(pos, pos) == '*' then
        pos = pos + 1
      end
      pos = space(text, pos)
      if text:sub(pos, pos) == '[' then
        local finish = group(text, pos, '[', ']')
        pos = finish and space(text, finish + 1) or start + #INCLUDEGRAPHICS_COMMAND
      end
      local finish = group(text, pos, '{', '}')
      if finish then
        local start_row, start_col = position(text, start, first)
        local end_row, end_col = position(text, finish + 1, first)
        if end_row - start_row + 1 > max_lines or finish - start + 1 > max_bytes then
          error_message = 'LaTeX image reference exceeds configured limits'
        elseif text:sub(pos + 1, finish - 1):find('\n', 1, true) then
          error_message = 'Multiline image filenames are not supported'
        else
          local src = literal(text:sub(pos + 1, finish - 1))
          if src and src ~= '' then
            results[#results + 1] = {
              src = src,
              start_row = start_row,
              start_col = start_col,
              end_row = end_row,
              end_col = end_col,
            }
          end
        end
        pos = finish + 1
        consumed = pos
      end
    end
    if anchored then
      break
    end
  end
  return results, error_message, consumed
end

-- Check inclusive row coverage and byte-column bounds on the first/last rows.
---@param reference table Decoded range with non-nil start_row/end_row and zero-based byte columns.
---@param row integer One-based row.
---@param col? integer Zero-based byte column; nil ignores horizontal bounds.
---@return boolean contains
function M.contains(reference, row, col)
  return row >= reference.start_row
    and row <= reference.end_row
    and (
      col == nil
      or (row > reference.start_row or col >= reference.start_col)
        and (row < reference.end_row or col < reference.end_col)
    )
end

-- Decode an anchored command without relying on a grammar's argument extent.
-- Generic starred commands and nested detokenize paths can have partial nodes.
-- Decode one anchored command with bounded lookahead independent of incomplete grammar argument
-- extents.
---@param buf integer Buffer id.
---@param row integer Zero-based command row.
---@param col integer Zero-based command byte column.
---@param opts table Reference budgets and optional scan ceiling.
---@return TexToolsImageReference[] references At most one anchored complete reference.
---@return string? error Reference budget/filename diagnostic.
---@return {end_row: integer, end_col: integer}? extent End of a complete command, including rejected arguments.
function M.at(buf, row, col, opts)
  local max_lines, max_bytes = M.limits(opts)
  local start_byte = vim.api.nvim_buf_get_offset(buf, row) + col
  local last = math.min(
    vim.api.nvim_buf_line_count(buf) - 1,
    row + max_lines - 1,
    (opts.max_scan_lines or defaults.max_scan_lines) - 1
  )
  if last < row then
    return {}
  end
  while last > row and vim.api.nvim_buf_get_offset(buf, last) >= start_byte + max_bytes do
    last = last - 1
  end
  local length = vim.api.nvim_buf_get_offset(buf, last + 1) - vim.api.nvim_buf_get_offset(buf, last) - 1
  local finish = math.min(length, start_byte + max_bytes - vim.api.nvim_buf_get_offset(buf, last))
  local text = table.concat(vim.api.nvim_buf_get_text(buf, row, col, last, finish, {}), '\n')
  local references, err, consumed = M.parse(text, row + 1, opts, true)
  local extent
  if consumed then
    local end_row, end_col = position(text, consumed, row + 1)
    extent = { end_row = end_row, end_col = end_col + (end_row == row + 1 and col or 0) }
  end
  for _, reference in ipairs(references) do
    if reference.start_row == row + 1 and reference.start_col == 0 then
      reference.start_col = col
      if reference.end_row == row + 1 then
        reference.end_col = reference.end_col + col
      end
      return { reference }, err, extent
    end
  end
  return {}, err, extent
end

return M
