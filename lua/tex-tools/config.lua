local M = {}

local defaults = {
  mappings = true,
  overwrite_mappings = false,
  smart_enter = false,
  conceal = false,
  viewer = { method = 'auto', executable = false, args = {} },
  build = { output_lines = 2000, main_file = false, profiles = {} },
  -- Additional math environments defined by your document class or packages.
  math_environments = {},
}

M.options = vim.deepcopy(defaults)

M.profile_fields = { 'executable', 'args', 'auxDirectory', 'logDirectory', 'pdfDirectory', 'filename' }

local function validate_profiles(profiles)
  vim.validate('build.profiles', profiles, 'table')
  for name, profile in pairs(profiles) do
    assert(
      type(name) == 'string' and name:match('^[%w_][%w_.-]*$') and name ~= 'toggle',
      'Compiler profile names must be identifiers other than toggle'
    )
    local key = 'build.profiles.' .. name
    vim.validate(key, profile, 'table')
    for field in pairs(profile) do
      assert(
        vim.tbl_contains(M.profile_fields, field),
        'Unknown compiler profile option: ' .. key .. '.' .. tostring(field)
      )
    end
    vim.validate(key .. '.executable', profile.executable, 'string')
    assert(
      profile.executable ~= '' and not profile.executable:find('%z'),
      key .. '.executable must be a nonempty executable path'
    )
    vim.validate(key .. '.args', profile.args, 'table')
    assert(vim.islist(profile.args), key .. '.args must be a list')
    for _, argument in ipairs(profile.args) do
      vim.validate(key .. '.args entry', argument, 'string')
      assert(not argument:find('%z'), key .. '.args must not contain NUL bytes')
    end
    for _, field in ipairs({ 'auxDirectory', 'logDirectory', 'pdfDirectory', 'filename' }) do
      local value = profile[field]
      if value ~= nil then
        vim.validate(key .. '.' .. field, value, 'string')
        assert(value ~= '' and not value:find('%z'), key .. '.' .. field .. ' must be a nonempty path')
      end
    end
    if profile.filename then
      assert(
        not profile.filename:find('[/\\]') and profile.filename ~= '.' and profile.filename ~= '..',
        key .. '.filename must be a basename without directory components'
      )
    end
  end
end

local conceal_categories =
  { 'accents', 'ligatures', 'cites', 'fancy', 'spacing', 'math_bounds', 'math_delimiters', 'styles', 'math_symbols' }

function M.setup(opts)
  opts = opts or {}
  vim.validate('opts', opts, 'table')
  local options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  vim.validate('mappings', options.mappings, 'boolean')
  vim.validate('overwrite_mappings', options.overwrite_mappings, 'boolean')
  vim.validate('smart_enter', options.smart_enter, 'boolean')
  vim.validate('build', options.build, 'table')
  vim.validate('build.output_lines', options.build.output_lines, 'number')
  assert(
    options.build.output_lines >= 1 and options.build.output_lines % 1 == 0,
    'build.output_lines must be a positive integer'
  )
  assert(
    options.build.main_file == false or (type(options.build.main_file) == 'string' and options.build.main_file ~= ''),
    'build.main_file must be false or a nonempty path'
  )
  validate_profiles(options.build.profiles)
  vim.validate('viewer', options.viewer, 'table')
  assert(vim.tbl_contains({ 'auto', 'skim', 'zathura', 'generic' }, options.viewer.method), 'Unknown viewer.method')
  assert(
    options.viewer.executable == false
      or (
        type(options.viewer.executable) == 'string'
        and options.viewer.executable ~= ''
        and not options.viewer.executable:find('%z')
      ),
    'viewer.executable must be false or a nonempty executable path'
  )
  vim.validate('viewer.args', options.viewer.args, 'table')
  assert(vim.islist(options.viewer.args), 'viewer.args must be a list')
  for _, value in ipairs(options.viewer.args) do
    assert(type(value) == 'string' and not value:find('%z'), 'viewer.args entries must be strings without NUL bytes')
  end
  vim.validate('conceal', options.conceal, { 'boolean', 'table' })
  if options.conceal ~= false then
    local conceal = type(options.conceal) == 'table' and options.conceal or {}
    local normalized = { enabled = true, symbols = {}, max_line_length = 10000 }
    for _, category in ipairs(conceal_categories) do
      normalized[category] = true
    end
    for name, value in pairs(conceal) do
      assert(normalized[name] ~= nil, 'Unknown conceal option: ' .. tostring(name))
      if name == 'max_line_length' then
        vim.validate('conceal.max_line_length', value, 'number')
        assert(
          value >= 0 and value < math.huge and value % 1 == 0,
          'conceal.max_line_length must be a nonnegative integer'
        )
        normalized[name] = value
      elseif name == 'symbols' then
        vim.validate('conceal.symbols', value, 'table')
        for command, glyph in pairs(value) do
          assert(
            type(command) == 'string' and command:match('^[A-Za-z@]+$'),
            'conceal.symbols keys must be literal command names without a backslash'
          )
          assert(
            glyph == false or (type(glyph) == 'string' and not glyph:find('%c') and vim.fn.strchars(glyph) == 1),
            'conceal.symbols values must be one printable Unicode character or false'
          )
        end
      else
        vim.validate('conceal.' .. name, value, 'boolean')
      end
      normalized[name] = value
    end
    options.conceal = normalized.enabled and normalized or false
  end
  vim.validate('math_environments', options.math_environments, 'table')
  assert(vim.islist(options.math_environments), 'math_environments must be a list')
  for _, name in ipairs(options.math_environments) do
    vim.validate('math environment', name, 'string')
  end
  M.options = options
end

return M
