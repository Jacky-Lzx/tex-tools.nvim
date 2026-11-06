-- LaTeX image preview semantics. Tree-sitter owns command positions/exclusions;
-- bounded decoding handles starred commands and detokenize grammar gaps.
-- No image-tools modules are imported here.
local M = {}
local ts = require('tex-tools.treesitter')
local literal = require('tex-tools.image.reference')
local snapshots = {}
local attached = {}
local function snapshot(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if snapshots[buf] and snapshots[buf].tick == tick then
    return snapshots[buf]
  end
  local root, err = ts.root(buf)
  if not root then
    return nil, err
  end
  local result = { tick = tick, commands = {}, paths = {} }
  local function visit(node)
    local kind = node:type()
    local row, col = node:range()
    if row >= 10000 or ts.comment_types[kind] or ts.literal_types[kind] or kind:match('_definition$') then
      return
    end
    local command = ts.field(node, 'command')
    local name = kind == 'graphics_include' and '\\includegraphics' or command and ts.text(command, buf)
    if name and not require('tex-tools.formula.detect').inline_literal(buf, row, col) then
      if name == '\\includegraphics' or name == '\\includegraphics*' then
        result.commands[#result.commands + 1] = { row = row, col = col, directories = result.paths }
        return -- Paths/options can contain command-like text; do not recurse into them.
      elseif name == '\\graphicspath' then
        local text = ts.text(node, buf)
        local first = literal.space(text, #'\\graphicspath' + 1)
        local last = literal.group(text, first, '{', '}')
        if last then
          local directories, pos = {}, literal.space(text, first + 1)
          while pos < last do
            local finish = literal.group(text, pos, '{', '}')
            if not finish then
              break
            end
            local directory = literal.literal(text:sub(pos + 1, finish - 1))
            if directory then
              directories[#directories + 1] = directory
            end
            pos = literal.space(text, finish + 1)
          end
          result.paths = directories
        end
      end
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end
  visit(root)
  snapshots[buf] = result
  if not attached[buf] then
    attached[buf] = vim.api.nvim_buf_attach(buf, false, {
      on_detach = function()
        snapshots[buf], attached[buf] = nil, nil
      end,
    })
  end
  return result
end

local function resolve(buf, source, directories, options)
  if source:find('%c') or source:match('^%a[%w+.-]*:') or source:sub(1, 2) == '//' then
    return nil, 'Image preview requires a literal local path'
  end
  local document = vim.api.nvim_buf_get_name(buf)
  local root = options.root
  if type(root) == 'function' then
    root = root(document)
  end
  local vimtex = vim.b[buf].vimtex
  root = root or (type(vimtex) == 'table' and vimtex.root) or (document ~= '' and vim.fs.dirname(document))
  if not root and source:sub(1, 1) ~= '/' then
    return nil, 'Save the document before previewing a relative image'
  end
  local paths = { source:sub(1, 1) == '/' and source or vim.fs.joinpath(root, source) }
  if source:sub(1, 1) ~= '/' then
    for _, directory in ipairs(directories) do
      local base = directory:sub(1, 1) == '/' and directory or vim.fs.joinpath(root, directory)
      paths[#paths + 1] = vim.fs.joinpath(base, source)
    end
  end
  for _, path in ipairs(paths) do
    for _, extension in ipairs({ '', '.pdf', '.png', '.jpg', '.jpeg' }) do
      local target = vim.fs.normalize(vim.fn.fnamemodify(path .. extension, ':p'))
      local stat = vim.uv.fs_stat(target)
      if stat and stat.type == 'file' then
        local version =
          table.concat({ target, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':')
        return target, nil, version
      end
    end
  end
  return nil, 'Image not found in document root or graphicspath: ' .. source
end

function M.find(buf, row, col, options)
  buf = ts.buffer(buf)
  if not vim.tbl_contains({ 'tex', 'latex', 'plaintex' }, vim.bo[buf].filetype) then
    return nil, 'Image preview supports LaTeX buffers'
  end
  -- Ordinary rows do not initialize an image index or parse a cold syntax tree.
  local first = math.max(0, row - options.max_lines + 1)
  local ending = vim.api.nvim_buf_get_offset(buf, row + 1)
  while first <= row and ending - vim.api.nvim_buf_get_offset(buf, first) > options.max_bytes do
    first = first + 1
  end
  if first > row then
    return nil, 'Image reference exceeds configured limits'
  end
  local nearby = table.concat(vim.api.nvim_buf_get_lines(buf, first, row + 1, false), '\n')
  if not nearby:find('\\includegraphics', 1, true) then
    return nil, 'No image reference on the current line'
  end
  local indexed, err = snapshot(buf)
  if not indexed then
    return nil, err
  end
  local refs = {}
  local budgets = { latex = { max_reference_lines = options.max_lines, max_reference_bytes = options.max_bytes } }
  for _, command in ipairs(indexed.commands) do
    if command.row > row then
      break
    end
    if row - command.row < options.max_lines then
      local candidates = literal.at(buf, command.row, command.col, budgets)
      for _, ref in ipairs(candidates) do
        if literal.contains(ref, row + 1) then
          refs[#refs + 1] = { reference = ref, directories = command.directories }
        end
      end
    end
  end
  local chosen = refs[1]
  for _, candidate in ipairs(refs) do
    if literal.contains(candidate.reference, row + 1, col) then
      chosen = candidate
      break
    end
  end
  if not chosen then
    return nil, 'No image reference on the current line'
  end
  local ref = chosen.reference
  local path, failure, version = resolve(buf, ref.src, chosen.directories, options)
  if not path then
    return nil, failure
  end
  return {
    kind = 'image',
    path = path,
    source = ref.src,
    range = { ref.start_row - 1, ref.start_col, ref.end_row - 1, ref.end_col },
    key = version,
  }
end
return M
