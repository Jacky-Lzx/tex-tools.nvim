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
  local attached = vim.lsp.get_clients({ name = 'texlab', bufnr = 0 })[1]
  if attached then
    local build = (((attached.settings or {}).texlab or {}).build or {})
    local executable = build.executable or 'latexmk'
    if vim.fn.executable(executable) == 1 then
      vim.health.ok('Compiler is executable: ' .. executable)
    else
      vim.health.warn('Compiler is unavailable: ' .. executable)
    end
    local info, message = require('tex-tools.project').info()
    if info then
      vim.health.ok('Main file: ' .. info.main_file .. ' (' .. info.main_source .. ')')
      vim.health.info('Build working directory: ' .. info.cwd)
      for _, artifact in ipairs({ { 'PDF', info.pdf_file }, { 'SyncTeX', info.synctex_file } }) do
        local exists = vim.fn.filereadable(artifact[2]) == 1
        if artifact[1] == 'SyncTeX' then
          exists = exists or vim.fn.filereadable(artifact[2]:gsub('%.gz$', '')) == 1
        end
        if exists then
          vim.health.ok(artifact[1] .. ': ' .. artifact[2])
        else
          vim.health.warn(
            artifact[1] .. ' is missing: ' .. artifact[2],
            { 'Compile with SyncTeX enabled for source/PDF synchronization' }
          )
        end
      end
    else
      vim.health.warn('Could not resolve main file: ' .. tostring(message))
    end
  end
  local viewer = require('tex-tools.viewer').detect(attached)
  if vim.fn.executable(viewer.executable) == 1 then
    vim.health.ok('PDF viewer: ' .. viewer.method .. ' (' .. viewer.executable .. ')')
  else
    vim.health.warn('PDF viewer executable is unavailable: ' .. viewer.executable)
  end
  if viewer.method == 'generic' then
    vim.health.info('The system PDF opener does not configure inverse search; use Skim or Zathura for callbacks')
  end
  if vim.v.servername ~= '' then
    vim.health.ok('Neovim RPC address: ' .. vim.v.servername)
  else
    vim.health.info('RPC starts on demand when generating a callback; setup and health checks do not start a server')
  end
end

return M
