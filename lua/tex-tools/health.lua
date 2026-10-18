local M = {}

function M.check()
  vim.health.start('tex-tools.nvim')
  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim >= 0.11')
  else
    vim.health.error('Neovim >= 0.11 is required')
  end
  local ok, err = pcall(vim.treesitter.language.add, 'latex')
  if ok and err ~= false then
    vim.health.ok('LaTeX Tree-sitter parser is available')
  else
    vim.health.error(
      'LaTeX Tree-sitter parser is unavailable',
      { 'Install latex with your parser manager (:TSInstall latex)' }
    )
  end
  local clients = vim.lsp.get_clients({ name = 'texlab' })
  if #clients > 0 then
    vim.health.ok('texlab is running')
  elseif vim.fn.executable('texlab') == 1 then
    vim.health.warn('texlab is installed but has no running client', { 'Enable texlab in your LSP configuration' })
  else
    vim.health.warn('texlab is unavailable; build and forward search need an attached texlab client')
  end
end

return M
