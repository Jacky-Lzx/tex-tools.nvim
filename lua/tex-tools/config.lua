local M = {}

local defaults = {
  mappings = true,
  smart_enter = false,
  conceal = false,
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
  { 'accents', 'ligatures', 'cites', 'fancy', 'spacing', 'math_bounds', 'math_delimiters', 'styles' }

function M.setup(opts)
  opts = opts or {}
  vim.validate('opts', opts, 'table')
  local options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  vim.validate('mappings', options.mappings, 'boolean')
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
  vim.validate('conceal', options.conceal, { 'boolean', 'table' })
  if options.conceal ~= false then
    local conceal = type(options.conceal) == 'table' and options.conceal or {}
    local normalized = { enabled = true }
    for _, category in ipairs(conceal_categories) do
      normalized[category] = true
    end
    for name, value in pairs(conceal) do
      assert(normalized[name] ~= nil, 'Unknown conceal option: ' .. tostring(name))
      vim.validate('conceal.' .. name, value, 'boolean')
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
