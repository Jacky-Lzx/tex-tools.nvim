local ts = require('tex-tools.treesitter')
local M = {}
local kinds = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}

function M.current(opts, count)
  local node, err = ts.editable_node(opts)
  local bufnr = ts.buffer(opts and opts.bufnr)
  while node do
    if kinds[node:type()] then
      local header, message = require('tex-tools.structure').command_node(node, bufnr)
      if message or not header or not ts.field(node, 'text') then
        return nil, message or 'Section heading is incomplete'
      end
      count = count - 1
      if count == 0 then
        local outer = ts.range(node)
        local sr, sc = header.outer[3], header.outer[4]
        local er, ec = outer[3], outer[4]
        local lines = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
        if sr < er and lines[1]:sub(sc + 1):match('^%s*$') then
          sr, sc = sr + 1, 0
        end
        local first = vim.api.nvim_buf_get_lines(bufnr, outer[1], outer[1] + 1, false)[1]
        local last = vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1]
        if first:sub(1, outer[2]):match('^%s*$') and last:sub(ec + 1):match('^%s*$') then
          outer[2] = 0
          if er + 1 < vim.api.nvim_buf_line_count(bufnr) then
            outer[3], outer[4] = er + 1, 0
          end
        end
        return { outer = outer, inner = { sr, sc, er, ec } }
      end
    end
    node = node:parent()
  end
  return nil, err or 'Not enough enclosing LaTeX sections'
end
return M
