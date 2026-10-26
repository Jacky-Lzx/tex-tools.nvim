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
  local lsp = require('tex-tools.lsp')
  local backend = lsp.backend()
  local clients = lsp.clients()
  if #clients > 0 then
    vim.health.ok(backend .. ' is running')
  elseif vim.fn.executable(backend) == 1 then
    vim.health.warn(backend .. ' is installed but has no running client', { 'Enable it in your LSP configuration' })
  else
    vim.health.warn(backend .. ' is unavailable; attach the selected LSP for builds and forward search')
  end
  local attached = lsp.clients(vim.api.nvim_get_current_buf())[1]
  if attached then
    local settings = backend == 'latex-lsp' and require('tex-tools.lsp.latex').settings(attached)
      or ((attached.settings or {}).texlab or {})
    local build = settings.build or {}
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
        local exists = artifact[2] and vim.fn.filereadable(artifact[2]) == 1
        if artifact[1] == 'SyncTeX' then
          exists = exists or (artifact[2] and vim.fn.filereadable(artifact[2]:gsub('%.gz$', '')) == 1)
        end
        if exists then
          vim.health.ok(artifact[1] .. ': ' .. artifact[2])
        elseif artifact[2] then
          vim.health.warn(
            artifact[1] .. ' is missing: ' .. artifact[2],
            { 'Compile with SyncTeX enabled for source/PDF synchronization' }
          )
        else
          vim.health.info(artifact[1] .. ' path is managed by the server; compile first')
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
  vim.health.info('Stable inverse-search registry: ' .. require('tex-tools.inverse').directory())
  if vim.v.servername ~= '' then
    vim.health.ok('Neovim RPC address: ' .. vim.v.servername)
  else
    vim.health.info(
      'RPC starts when a local TeX buffer registers or a callback is generated; health checks do not start it'
    )
  end
end

return M
