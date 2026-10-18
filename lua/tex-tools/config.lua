local M = {}

local defaults = {
  mappings = true,
  smart_enter = false,
  -- Additional math environments defined by your document class or packages.
  math_environments = {},
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  vim.validate('opts', opts, 'table')
  local options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  vim.validate('mappings', options.mappings, 'boolean')
  vim.validate('smart_enter', options.smart_enter, 'boolean')
  vim.validate('math_environments', options.math_environments, 'table')
  assert(vim.islist(options.math_environments), 'math_environments must be a list')
  for _, name in ipairs(options.math_environments) do
    vim.validate('math environment', name, 'string')
  end
  M.options = options
end

return M
