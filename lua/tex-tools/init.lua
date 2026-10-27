local M = {}
local generation = 0

local function action(module, method, ...)
  local ok, err = require('tex-tools.' .. module)[method](...)
  if not ok and err then
    vim.notify(err, vim.log.levels.WARN, { title = 'tex-tools' })
  end
end

local function attach(bufnr)
  -- Filetype-based loaders may replay FileType after setup already attached
  -- the current buffer. Explicit setup calls start a new generation.
  if vim.b[bufnr].tex_tools_generation == generation then
    return
  end
  require('tex-tools.inverse').track(bufnr)
  local mappings = require('tex-tools.mappings')
  mappings.clear(bufnr)
  local enter_plug = '<Plug>(TexToolsSmartEnter)'
  vim.keymap.set('i', enter_plug, M.smart_enter, {
    buffer = bufnr,
    expr = true,
    replace_keycodes = false,
    desc = 'tex-tools: SmartEnter',
  })
  local options = require('tex-tools.config').options
  if options.conceal or package.loaded['tex-tools.conceal'] then
    require('tex-tools.conceal').attach(bufnr, options.conceal)
  end
  if options.mappings and options.smart_enter then
    mappings.set(
      bufnr,
      'i',
      '<CR>',
      enter_plug,
      { remap = true, desc = 'tex-tools: SmartEnter' },
      options.overwrite_mappings
    )
  end
  local commands = {
    TexToolsOutline = {
      function(args)
        action('outline', 'open', { project = args.bang, query = args.args })
      end,
      { bang = true, nargs = '?', desc = 'Search and navigate file or project sections' },
    },
    TexToolsToggleCommandStar = {
      function()
        action('command', 'toggle_star')
      end,
      { desc = 'Toggle the surrounding command star' },
    },
    TexToolsToggleFraction = {
      function()
        action('fraction', 'toggle')
      end,
      { desc = 'Toggle a braced fraction and a slash expression' },
    },
    TexToolsConvertMath = {
      function(args)
        action('math', 'convert', args.args)
      end,
      {
        nargs = 1,
        complete = function()
          return { 'inline', 'display', 'equation', 'equation*', 'align', 'align*', 'gather', 'gather*' }
        end,
        desc = 'Convert the surrounding formula or math environment',
      },
    },
    TexToolsToggleMathMode = {
      function()
        action('math', 'toggle_mode')
      end,
      { desc = 'Toggle inline and display math' },
    },
    TexToolsCloseDelimiter = {
      function()
        action('close', 'insert')
      end,
      { desc = 'Insert the nearest missing closing marker' },
    },
    TexToolsView = {
      function()
        action('viewer', 'view')
      end,
      { desc = 'Open the resolved PDF without forward search' },
    },
    TexToolsInverseSearch = {
      function(args)
        action('viewer', 'show_callback', args.args ~= '' and args.args or 'skim')
      end,
      {
        nargs = '?',
        complete = function()
          return { 'skim', 'zathura', 'pagewing' }
        end,
        desc = 'Show the native inverse-search callback',
      },
    },
    TexToolsMain = {
      function(args)
        action('project', 'command', args.args ~= '' and args.args or nil)
      end,
      { nargs = '?', complete = 'file', desc = 'Show, select or reset the main TeX file' },
    },
    TexToolsInfo = {
      function()
        action('project', 'show_info')
      end,
      { desc = 'Show main file, compiler and artifact paths' },
    },
    TexToolsJumpMathDelimiter = {
      function(args)
        action('delimiter', 'jump', args.count)
      end,
      { count = 1, desc = 'Jump between matching math bracket markers' },
    },
    TexToolsChangeMathDelimiters = {
      function(args)
        action('delimiter', 'change', args.args ~= '' and args.args or nil)
      end,
      { nargs = '?', desc = 'Change the surrounding math delimiter pair' },
    },
    TexToolsUnwrapMathDelimiters = {
      function()
        action('delimiter', 'unwrap')
      end,
      { desc = 'Remove the surrounding math delimiter pair, keeping its contents' },
    },
    TexToolsToggleMathDelimiterSize = {
      function()
        action('delimiter', 'toggle_size')
      end,
      { desc = 'Toggle automatic math delimiter sizing with left/right' },
    },
    TexToolsRenameCommand = {
      function(args)
        action('command', 'rename', args.args ~= '' and args.args or nil)
      end,
      { nargs = '?', desc = 'Rename the surrounding LaTeX command' },
    },
    TexToolsUnwrapCommand = {
      function()
        action('command', 'unwrap')
      end,
      { desc = 'Remove a single-argument LaTeX command, keeping its contents' },
    },
    TexToolsSurroundCommand = {
      function(args)
        action('command', 'surround', args.args ~= '' and args.args or nil, { line1 = args.line1, line2 = args.line2 })
      end,
      { nargs = '?', range = true, desc = 'Surround lines with a LaTeX command' },
    },
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
    TexToolsClean = {
      function()
        action('clean', 'clean', false)
      end,
      { desc = 'Clean auxiliary build files' },
    },
    TexToolsCleanFull = {
      function()
        action('clean', 'clean', true)
      end,
      { desc = 'Clean build artifacts including the PDF' },
    },
    TexToolsForwardSearch = {
      function()
        action('lsp', 'forward_search')
      end,
      { desc = 'Forward search with the attached texlab client' },
    },
    TexToolsCancelBuild = {
      function()
        action('lsp', 'cancel_build')
      end,
      { desc = 'Cancel builds in the attached texlab client' },
    },
    TexToolsCancelAllBuilds = {
      function()
        action('lsp', 'cancel_all_builds')
      end,
      { desc = 'Cancel builds in all texlab clients' },
    },
    TexToolsBuildStatus = {
      function()
        action('lsp', 'show_build_status')
      end,
      { desc = 'Show compilation status and automatic build setting' },
    },
    TexToolsCompiler = {
      function(args)
        action('compiler', 'command', args.args ~= '' and args.args or nil)
      end,
      {
        nargs = '?',
        complete = function(lead)
          local names = require('tex-tools.compiler').names()
          names[#names + 1] = 'toggle'
          return vim.tbl_filter(function(name)
            return name:sub(1, #lead) == lead
          end, names)
        end,
        desc = 'Show or switch the attached texlab compiler profile',
      },
    },
    TexToolsBuildOutput = {
      function()
        action('build_output', 'open')
      end,
      { desc = 'Open live texlab compiler output' },
    },
    TexToolsLog = {
      function(args)
        action('build_output', 'log', args.args ~= '' and args.args or nil)
      end,
      { nargs = '?', complete = 'file', desc = 'View the full compiler log' },
    },
    TexToolsErrors = {
      function(args)
        action('build_output', 'errors', { errors_only = args.bang })
      end,
      { bang = true, desc = 'Show texlab errors and warnings in quickfix (! for errors only)' },
    },
    TexToolsBuildOnSave = {
      function(args)
        local enabled
        if args.args ~= '' and args.args ~= 'toggle' then
          enabled = args.args == 'on'
          if args.args ~= 'on' and args.args ~= 'off' then
            vim.notify('Use on, off, or toggle', vim.log.levels.WARN, { title = 'tex-tools' })
            return
          end
        end
        action('lsp', 'build_on_save', enabled)
      end,
      {
        nargs = '?',
        complete = function()
          return { 'on', 'off', 'toggle' }
        end,
        desc = 'Enable, disable or toggle texlab build on save',
      },
    },
  }
  for _, kind in ipairs({ 'Section', 'Item', 'Environment', 'Math' }) do
    for _, direction in ipairs({ { 'Next', 1 }, { 'Previous', -1 } }) do
      commands['TexTools' .. direction[1] .. kind] = {
        function(args)
          action('navigation', kind:lower(), direction[2], args.count)
        end,
        { count = 1, desc = 'Jump to the ' .. direction[1]:lower() .. ' LaTeX ' .. kind:lower() },
      }
    end
  end
  for _, entry in ipairs({ { 'PromoteSection', -1 }, { 'DemoteSection', 1 } }) do
    commands['TexTools' .. entry[1]] = {
      function(args)
        action('section', 'shift', entry[2], args.count)
      end,
      { count = 1, desc = 'Shift the current section and all its subsections' },
    }
  end
  for _, entry in ipairs({ { 'NextCell', 1 }, { 'PreviousCell', -1 } }) do
    commands['TexTools' .. entry[1]] = {
      function(args)
        action('table', 'jump', entry[2], args.count)
      end,
      { count = 1, desc = 'Jump between table cells' },
    }
  end
  for _, entry in ipairs({
    { 'InsertRow', 'insert_row' },
    { 'DeleteRow', 'delete_row' },
    { 'InsertColumn', 'insert_column' },
    { 'DeleteColumn', 'delete_column' },
  }) do
    commands['TexTools' .. entry[1]] = {
      function()
        action('table', 'edit', entry[2])
      end,
      { desc = 'Edit the surrounding table: ' .. entry[2] },
    }
  end
  for name, command in pairs(commands) do
    vim.api.nvim_buf_create_user_command(bufnr, name, command[1], command[2])
  end
  local maps = {
    {
      'n',
      '<localleader>lt',
      'Outline',
      function()
        action('outline', 'open')
      end,
    },
    {
      'n',
      false,
      'ProjectOutline',
      function()
        action('outline', 'open', { project = true })
      end,
    },
    {
      'n',
      false,
      'ToggleCommandStar',
      function()
        action('command', 'toggle_star')
      end,
    },
    {
      'n',
      false,
      'ToggleFraction',
      function()
        action('fraction', 'toggle')
      end,
    },
    {
      'n',
      false,
      'ToggleMathMode',
      function()
        action('math', 'toggle_mode')
      end,
    },
    {
      'i',
      ']]',
      'CloseDelimiter',
      function()
        return require('tex-tools.close').keys()
      end,
      expr = true,
    },
    {
      'n',
      '<localleader>lc',
      'Clean',
      function()
        action('clean', 'clean', false)
      end,
    },
    {
      'n',
      '<localleader>lC',
      'CleanFull',
      function()
        action('clean', 'clean', true)
      end,
    },
    {
      'n',
      '<localleader>lo',
      'BuildOutput',
      function()
        action('build_output', 'open')
      end,
    },
    {
      'n',
      '<localleader>lq',
      'Log',
      function()
        action('build_output', 'log')
      end,
    },
    {
      'n',
      '<localleader>le',
      'Errors',
      function()
        action('build_output', 'errors')
      end,
    },
    {
      'n',
      '<localleader>lk',
      'CancelBuild',
      function()
        action('lsp', 'cancel_build')
      end,
    },
    {
      'n',
      '<localleader>lK',
      'CancelAllBuilds',
      function()
        action('lsp', 'cancel_all_builds')
      end,
    },
    {
      'n',
      '<localleader>lg',
      'BuildStatus',
      function()
        action('lsp', 'show_build_status')
      end,
    },
    {
      'n',
      '<localleader>ldm',
      'JumpMathDelimiter',
      function()
        action('delimiter', 'jump', vim.v.count1)
      end,
    },
    {
      'n',
      '<localleader>ldc',
      'ChangeMathDelimiters',
      function()
        action('delimiter', 'change')
      end,
    },
    {
      'n',
      '<localleader>ldd',
      'UnwrapMathDelimiters',
      function()
        action('delimiter', 'unwrap')
      end,
    },
    {
      'n',
      '<localleader>ldt',
      'ToggleMathDelimiterSize',
      function()
        action('delimiter', 'toggle_size')
      end,
    },
    {
      'n',
      '<localleader>lcr',
      'RenameCommand',
      function()
        action('command', 'rename')
      end,
    },
    {
      'n',
      '<localleader>lcd',
      'UnwrapCommand',
      function()
        action('command', 'unwrap')
      end,
    },
    {
      'n',
      '<localleader>lcs',
      'SurroundCommand',
      function()
        action('command', 'surround')
      end,
    },
    {
      'x',
      '<localleader>lcs',
      'SurroundCommand',
      function()
        action('command', 'surround_visual')
      end,
    },
    {
      'n',
      '<localleader>li',
      'InsertItem',
      function()
        action('list', 'insert')
      end,
    },
    {
      'i',
      false,
      'InsertItem',
      function()
        action('list', 'insert')
      end,
    },
    {
      'n',
      '<localleader>lEd',
      'UnwrapEnvironment',
      function()
        action('environment', 'unwrap')
      end,
    },
    {
      'n',
      '<localleader>lEs',
      'SurroundEnvironment',
      function()
        action('environment', 'surround')
      end,
    },
    {
      'x',
      '<localleader>lEs',
      'SurroundEnvironment',
      function()
        action('environment', 'surround_visual')
      end,
    },
    {
      'n',
      '<localleader>lf',
      'ToggleMathDelimiters',
      function()
        action('math', 'toggle_delimiters')
      end,
    },
    {
      'n',
      '<localleader>lEr',
      'RenameEnvironment',
      function()
        action('environment', 'rename')
      end,
    },
    {
      'n',
      '<localleader>lEt',
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
  }
  for _, entry in ipairs({ { 'PromoteSection', -1 }, { 'DemoteSection', 1 } }) do
    maps[#maps + 1] = {
      'n',
      false,
      entry[1],
      function()
        action('section', 'shift', entry[2], vim.v.count1)
      end,
    }
  end
  for _, entry in ipairs({ { 'NextCell', ']t', 1 }, { 'PreviousCell', '[t', -1 } }) do
    maps[#maps + 1] = {
      'n',
      entry[2],
      entry[1],
      function()
        action('table', 'jump', entry[3], vim.v.count1)
      end,
    }
  end
  for _, entry in ipairs({
    { 'InsertRow', 'insert_row' },
    { 'DeleteRow', 'delete_row' },
    { 'InsertColumn', 'insert_column' },
    { 'DeleteColumn', 'delete_column' },
  }) do
    maps[#maps + 1] = {
      'n',
      false,
      entry[1],
      function()
        action('table', 'edit', entry[2])
      end,
    }
  end
  for _, kind in ipairs({
    { 'Section', ']]', '[[' },
    { 'Item', ']i', '[i' },
    { 'Environment', ']e', '[e' },
    { 'Math', ']m', '[m' },
  }) do
    for _, direction in ipairs({ { 'Next', 1, 2 }, { 'Previous', -1, 3 } }) do
      maps[#maps + 1] = {
        'n',
        kind[direction[3]],
        direction[1] .. kind[1],
        function()
          action('navigation', kind[1]:lower(), direction[2], vim.v.count1)
        end,
      }
    end
  end
  for _, object in ipairs({
    { 'environment', 'e', 'Environment' },
    { 'command', 'c', 'Command' },
    { 'argument', 'a', 'Argument' },
    { 'math', '$', 'Math' },
    { 'delimiter', 'd', 'MathDelimiter' },
    { 'item', 'i', 'Item' },
    { 'section', 'P', 'Section' },
    { 'cell', 't', 'Cell' },
  }) do
    for _, variant in ipairs({ { 'a', 'Around', false }, { 'i', 'Inside', true } }) do
      maps[#maps + 1] = {
        { 'x', 'o' },
        variant[1] .. object[2],
        variant[2] .. object[3],
        function()
          return require('tex-tools.textobjects').mapping(object[1], variant[3], vim.v.count1)
        end,
        expr = true,
      }
    end
  end
  for _, map in ipairs(maps) do
    local plug = '<Plug>(TexTools' .. map[3] .. ')'
    local plug_options = { buffer = bufnr, silent = true, desc = 'tex-tools: ' .. map[3] }
    if map.expr then
      plug_options.expr = true
      plug_options.replace_keycodes = false
    end
    vim.keymap.set(map[1], plug, map[4], plug_options)
    if options.mappings and map[2] then
      mappings.set(
        bufnr,
        map[1],
        map[2],
        plug,
        { remap = true, silent = true, desc = 'tex-tools: ' .. map[3] },
        options.overwrite_mappings
      )
    end
  end
  vim.b[bufnr].tex_tools_generation = generation
end

function M.setup(opts)
  if vim.fn.has('nvim-0.11') == 0 then
    error('tex-tools.nvim requires Neovim 0.11 or newer')
  end
  require('tex-tools.config').setup(opts)
  local lsp_group = vim.api.nvim_create_augroup('TexToolsLsp', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = lsp_group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and require('tex-tools.lsp').matches(client) then
        require('tex-tools.lsp').attach(client, event.buf)
      end
    end,
  })
  if package.loaded['vim.lsp'] then
    for _, client in ipairs(require('tex-tools.lsp').clients()) do
      require('tex-tools.lsp').attach(client)
    end
  end
  generation = generation + 1
  local inverse_group = vim.api.nvim_create_augroup('TexToolsInverseTracking', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufFilePost', 'FocusGained' }, {
    group = inverse_group,
    callback = function(event)
      local bufnr = event.buf
      if vim.api.nvim_buf_is_valid(bufnr) and vim.tbl_contains({ 'tex', 'plaintex' }, vim.bo[bufnr].filetype) then
        require('tex-tools.inverse').track(bufnr)
      end
    end,
  })
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
function M.in_subscript(opts)
  return require('tex-tools.context').in_subscript(opts)
end
function M.in_superscript(opts)
  return require('tex-tools.context').in_superscript(opts)
end
function M.in_numerator(opts)
  return require('tex-tools.context').in_numerator(opts)
end
function M.in_denominator(opts)
  return require('tex-tools.context').in_denominator(opts)
end
function M.in_table_cell(opts)
  return require('tex-tools.context').in_table_cell(opts)
end
function M.environment(opts)
  return require('tex-tools.environment').current(opts)
end
function M.rename_command(name)
  return require('tex-tools.command').rename(name)
end
function M.unwrap_command()
  return require('tex-tools.command').unwrap()
end
function M.surround_command(name, opts)
  return require('tex-tools.command').surround(name, opts)
end
function M.surround_command_visual(name)
  return require('tex-tools.command').surround_visual(name)
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
function M.toggle_command_star()
  return require('tex-tools.command').toggle_star()
end
function M.toggle_fraction()
  return require('tex-tools.fraction').toggle()
end
function M.convert_math(target)
  return require('tex-tools.math').convert(target)
end
function M.toggle_math_mode()
  return require('tex-tools.math').toggle_mode()
end
function M.close_delimiter()
  return require('tex-tools.close').insert()
end
function M.close_delimiter_keys()
  return require('tex-tools.close').keys()
end
function M.change_math_delimiters(name)
  return require('tex-tools.delimiter').change(name)
end
function M.unwrap_math_delimiters()
  return require('tex-tools.delimiter').unwrap()
end
function M.toggle_math_delimiter_size()
  return require('tex-tools.delimiter').toggle_size()
end
function M.jump_math_delimiter(count)
  return require('tex-tools.delimiter').jump(count)
end
function M.insert_item()
  return require('tex-tools.list').insert()
end
function M.smart_enter()
  return require('tex-tools.list').smart_enter()
end
function M.jump_section(direction, count)
  return require('tex-tools.navigation').section(direction, count)
end
function M.jump_item(direction, count)
  return require('tex-tools.navigation').item(direction, count)
end
function M.jump_environment_start(direction, count)
  return require('tex-tools.navigation').environment(direction, count)
end
function M.jump_math(direction, count)
  return require('tex-tools.navigation').math(direction, count)
end
function M.outline(opts)
  return require('tex-tools.outline').open(opts)
end
function M.outline_entries(opts)
  return require('tex-tools.outline').entries(opts)
end
function M.shift_section(direction, count)
  return require('tex-tools.section').shift(direction, count)
end
function M.jump_cell(direction, count)
  return require('tex-tools.table').jump(direction, count)
end
function M.table_edit(operation)
  return require('tex-tools.table').edit(operation)
end
function M.textobject_range(kind, inner, opts)
  return require('tex-tools.textobjects').range(kind, inner, opts)
end
function M.select_textobject(kind, inner, count)
  return require('tex-tools.textobjects').select(kind, inner, count)
end
function M.build()
  return require('tex-tools.lsp').build()
end
function M.view()
  return require('tex-tools.viewer').view()
end
function M.inverse_search(file, line, column)
  return require('tex-tools.viewer').inverse_search(file, line, column)
end
function M.inverse_search_command(kind)
  return require('tex-tools.viewer').callback(kind or 'skim')
end
function M.forward_search()
  return require('tex-tools.lsp').forward_search()
end

function M.inverse_search_position(page, x, y)
  if require('tex-tools.lsp').backend() ~= 'texquill' then
    return false, 'PDF coordinate queries require texquill'
  end
  return require('tex-tools.lsp.texquill').inverse_search(page, x, y)
end

function M.cancel_build()
  return require('tex-tools.lsp').cancel_build()
end
function M.cancel_all_builds()
  return require('tex-tools.lsp').cancel_all_builds()
end
function M.build_status()
  return require('tex-tools.lsp').build_status()
end
function M.build_on_save(enabled)
  return require('tex-tools.lsp').build_on_save(enabled)
end
function M.compiler(name)
  return require('tex-tools.compiler').select(name)
end
function M.main_file(path)
  return require('tex-tools.project').main_file(path)
end
function M.project_info()
  return require('tex-tools.project').info()
end
function M.build_output()
  return require('tex-tools.build_output').open()
end
function M.build_log(path)
  return require('tex-tools.build_output').log(path)
end
function M.build_errors(opts)
  return require('tex-tools.build_output').errors(opts)
end
function M.clean(full)
  return require('tex-tools.clean').clean(full)
end

return M
