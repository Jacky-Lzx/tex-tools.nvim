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
  local enter_plug = '<Plug>(TexToolsSmartEnter)'
  vim.keymap.set('i', enter_plug, M.smart_enter, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    desc = 'tex-tools: SmartEnter',
  })
  local options = require('tex-tools.config').options
  if options.mappings and options.smart_enter then
    vim.api.nvim_buf_call(bufnr, function()
      if vim.fn.maparg('<CR>', 'i') == '' then
        vim.keymap.set('i', '<CR>', enter_plug, { buffer = bufnr, remap = true, desc = 'tex-tools: SmartEnter' })
        installed[#installed + 1] = {
          mode = 'i',
          lhs = vim.fn.maparg('<CR>', 'i', false, true).lhs,
          rhs = enter_plug,
        }
      end
    end)
  end
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
    TexToolsSurroundEnvironment = {
      function(args)
        action(
          'environment',
          'surround',
          args.args ~= '' and args.args or nil,
          { line1 = args.line1, line2 = args.line2 }
        )
      end,
      { nargs = '?', range = true, desc = 'Surround lines with a LaTeX environment' },
    },
    TexToolsUnwrapEnvironment = {
      function()
        action('environment', 'unwrap')
      end,
      { desc = 'Remove the surrounding environment markers, keeping the body' },
    },
    TexToolsToggleMathDelimiters = {
      function()
        action('math', 'toggle_delimiters')
      end,
      { desc = 'Switch between dollar and backslash math delimiters' },
    },
    TexToolsInsertItem = {
      function()
        action('list', 'insert')
      end,
      { desc = 'Insert a sibling LaTeX list item and enter Insert mode' },
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
      { 'n', 'i' },
      '<localleader>li',
      'InsertItem',
      function()
        action('list', 'insert')
      end,
    },
    {
      'n',
      'dse',
      'UnwrapEnvironment',
      function()
        action('environment', 'unwrap')
      end,
    },
    {
      'n',
      '<localleader>le',
      'SurroundEnvironment',
      function()
        action('environment', 'surround')
      end,
    },
    {
      'x',
      '<localleader>le',
      'SurroundEnvironment',
      function()
        action('environment', 'surround_visual')
      end,
    },
    {
      'n',
      'ts$',
      'ToggleMathDelimiters',
      function()
        action('math', 'toggle_delimiters')
      end,
    },
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
  for _, object in ipairs({ { 'command', 'c', 'Command' }, { 'argument', 'a', 'Argument' }, { 'math', '$', 'Math' } }) do
    for _, variant in ipairs({ { 'a', 'Around', false }, { 'i', 'Inside', true } }) do
      maps[#maps + 1] = {
        { 'x', 'o' },
        variant[1] .. object[2],
        variant[2] .. object[3],
        function()
          action('textobjects', 'select', object[1], variant[3])
        end,
      }
    end
  end
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
function M.surround_environment(name, opts)
  return require('tex-tools.environment').surround(name, opts)
end
function M.unwrap_environment()
  return require('tex-tools.environment').unwrap()
end
function M.toggle_math_delimiters()
  return require('tex-tools.math').toggle_delimiters()
end
function M.insert_item()
  return require('tex-tools.list').insert()
end
function M.smart_enter()
  return require('tex-tools.list').smart_enter()
end
function M.textobject_range(kind, inner, opts)
  return require('tex-tools.textobjects').range(kind, inner, opts)
end
function M.select_textobject(kind, inner)
  return require('tex-tools.textobjects').select(kind, inner)
end
function M.build()
  return require('tex-tools.lsp').build()
end
function M.forward_search()
  return require('tex-tools.lsp').forward_search()
end

return M
