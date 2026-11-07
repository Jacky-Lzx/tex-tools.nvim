local M = {}

function M.check()
  vim.health.start('tex-tools.nvim')
  if vim.fn.has('nvim-0.11') == 0 then
    vim.health.error('Neovim 0.11+ is required', { 'Upgrade Neovim' })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded['tex-tools']
  local config = package.loaded['tex-tools.config']
  if not plugin or not config then
    vim.health.info('Not configured; TeX feature checks skipped.')
    return
  end
  if #vim.api.nvim_get_runtime_file('parser/latex.*', false) == 0 then
    problem(
      'error',
      'LaTeX parser is unavailable; syntax-based TeX operations cannot run.',
      { 'Install the latex parser with your configured parser manager' }
    )
  end
  local formulas = config.formula_options()
  if formulas.enabled then
    local missing = {}
    for _, cmd in ipairs({ formulas.latex, formulas.dvipng }) do
      if vim.fn.executable(cmd) == 0 then
        missing[#missing + 1] = cmd
      end
    end
    if #missing > 0 then
      problem(
        'warn',
        'Formula tools unavailable: ' .. table.concat(missing, ', ') .. '; formula previews cannot render.',
        { 'Install the configured TeX tools or disable formula_preview' }
      )
    end
  end
  if
    (formulas.enabled or config.options.image_preview.enabled)
    and #vim.api.nvim_get_runtime_file('lua/image_tools/init.lua', false) == 0
  then
    problem(
      'warn',
      'image-tools is unavailable; enabled image or formula previews cannot display.',
      { 'Install/mount image-tools.nvim or disable the preview features' }
    )
  end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' then
    local alternate = vim.fn.bufnr('#')
    buf = alternate > 0 and vim.api.nvim_buf_is_loaded(alternate) and alternate or nil
  end
  local ft = buf and vim.bo[buf].filetype
  if ft == 'tex' or ft == 'plaintex' then
    local lsp = require('tex-tools.lsp')
    local backend = lsp.backend()
    local attached = lsp.clients(buf)[1]
    if not attached and vim.fn.executable(backend) == 0 then
      problem(
        'warn',
        backend .. ': unavailable; builds and forward search need the selected server.',
        { 'Install/configure the selected LSP server; inspect :TexToolsInfo' }
      )
    elseif attached then
      local settings = backend == 'texquill' and require('tex-tools.lsp.texquill').settings(attached)
        or ((attached.settings or {}).texlab or {})
      local cmd = (settings.build or {}).executable or 'latexmk'
      if vim.fn.executable(cmd) == 0 then
        problem(
          'warn',
          cmd .. ': compiler unavailable; LaTeX builds cannot run.',
          { 'Install the compiler or correct the server build settings' }
        )
      end
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == 'error'
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok('Applicable TeX runtime requirements are satisfied.')
  end
  vim.health.info('Details: :TexToolsInfo')
end

return M
