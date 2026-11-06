vim.opt.rtp:prepend(vim.fn.getcwd())
local tex = require('tex-tools')
tex.setup()
vim.bo.filetype = 'tex'
for _, mode in ipairs({ 'n', 'x', 'o', 'i' }) do
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
    assert(mapping.lhs:find('<Plug>(TexTools', 1, true), 'Unexpected user key: ' .. mapping.lhs)
  end
end
assert(vim.fn.exists(':TexToolsInfo') == 2)
vim.keymap.set('o', 'iz', '<Plug>(TexToolsInsideArgument)', { buffer = true })
tex.setup()
assert(vim.fn.maparg('iz', 'o') == '<Plug>(TexToolsInsideArgument)')
print('TeX default keys remain user-owned; commands and Plug endpoints are available')
