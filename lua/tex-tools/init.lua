local M = {}

local function clear_default_mappings(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    for _, map in ipairs(vim.b[bufnr].tex_tools_default_mappings or {}) do
      local current = vim.fn.maparg(map.lhs, map.mode, false, true)
      if current.buffer == 1 and current.rhs == map.rhs then
        vim.keymap.del(map.mode, map.lhs, { buffer = bufnr })
      end
    end
  end)
  vim.b[bufnr].tex_tools_default_mappings = {}
end

local function action(module, method, ...)
  local ok, err = require('tex-tools.' .. module)[method](...)
  if not ok and err then
    vim.notify(err, vim.log.levels.WARN, { title = 'tex-tools' })
  end
end

local function attach(bufnr)
  clear_default_mappings(bufnr)
  local installed = {}
  local commands = {
    TexToolsRenameEnvironment = {
      function(args)
        action('environment', 'rename', args.args ~= '' and args.args or nil)
      end,
      { nargs = '?', desc = 'Rename the surrounding LaTeX environment' },
    },
    TexToolsToggleEnvironmentStar = {
      function()
        action('environment', 'toggle_star')
      end,
      { desc = 'Toggle the surrounding environment star' },
    },
    TexToolsJumpEnvironment = {
      function()
        action('environment', 'jump')
      end,
      { desc = 'Jump between LaTeX begin/end markers' },
    },
    TexToolsBuild = {
      function()
        action('lsp', 'build')
      end,
      { desc = 'Build with the attached texlab client' },
    },
    TexToolsForwardSearch = {
      function()
        action('lsp', 'forward_search')
      end,
      { desc = 'Forward search with the attached texlab client' },
    },
  }
  for name, command in pairs(commands) do
    vim.api.nvim_buf_create_user_command(bufnr, name, command[1], command[2])
  end
  local maps = {
    {
      'n',
      'cse',
      'RenameEnvironment',
      function()
        action('environment', 'rename')
      end,
    },
    {
      'n',
      'tss',
      'ToggleEnvironmentStar',
      function()
        action('environment', 'toggle_star')
      end,
    },
    {
      'n',
      '<localleader>lm',
      'JumpEnvironment',
      function()
        action('environment', 'jump')
      end,
    },
    {
      'n',
      '<localleader>ll',
      'Build',
      function()
        action('lsp', 'build')
      end,
    },
    {
      'n',
      '<localleader>lv',
      'ForwardSearch',
      function()
        action('lsp', 'forward_search')
      end,
    },
    {
      { 'x', 'o' },
      'ae',
      'AroundEnvironment',
      function()
        action('textobjects', 'select_environment', false)
      end,
    },
    {
      { 'x', 'o' },
      'ie',
      'InsideEnvironment',
      function()
        action('textobjects', 'select_environment', true)
      end,
    },
  }
  for _, map in ipairs(maps) do
    local plug = '<Plug>(TexTools' .. map[3] .. ')'
    vim.keymap.set(map[1], plug, map[4], { buffer = bufnr, silent = true, desc = 'tex-tools: ' .. map[3] })
    if require('tex-tools.config').options.mappings then
      -- Do not replace an existing global or buffer-local user mapping.
      vim.api.nvim_buf_call(bufnr, function()
        for _, mode in ipairs(type(map[1]) == 'table' and map[1] or { map[1] }) do
          if vim.fn.maparg(map[2], mode) == '' then
            vim.keymap.set(
              mode,
              map[2],
              plug,
              { buffer = bufnr, remap = true, silent = true, desc = 'tex-tools: ' .. map[3] }
            )
            installed[#installed + 1] = {
              mode = mode,
              lhs = vim.fn.maparg(map[2], mode, false, true).lhs,
              rhs = plug,
            }
          end
        end
      end)
    end
  end
  vim.b[bufnr].tex_tools_default_mappings = installed
end

function M.setup(opts)
  if vim.fn.has('nvim-0.11') == 0 then
    error('tex-tools.nvim requires Neovim 0.11 or newer')
  end
  require('tex-tools.config').setup(opts)
  local group = vim.api.nvim_create_augroup('TexTools', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'tex', 'plaintex' },
    callback = function(event)
      attach(event.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains({ 'tex', 'plaintex' }, vim.bo[bufnr].filetype) then
      attach(bufnr)
    end
  end
end

-- Small public API for snippet engines and user mappings; no setup side effects.
function M.in_math(opts)
  return require('tex-tools.context').in_math(opts)
end
function M.in_comment(opts)
  return require('tex-tools.context').in_comment(opts)
end
function M.environment(opts)
  return require('tex-tools.environment').current(opts)
end
function M.rename_environment(name)
  return require('tex-tools.environment').rename(name)
end
function M.toggle_environment_star()
  return require('tex-tools.environment').toggle_star()
end
function M.jump_environment()
  return require('tex-tools.environment').jump()
end
function M.build()
  return require('tex-tools.lsp').build()
end
function M.forward_search()
  return require('tex-tools.lsp').forward_search()
end

return M
