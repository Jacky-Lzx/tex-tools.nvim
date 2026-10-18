local M = {}

function M.names()
  local names = vim.tbl_keys(require('tex-tools.config').options.build.profiles)
  table.sort(names)
  return names
end

local function matches(build, profile)
  for _, field in ipairs(require('tex-tools.config').profile_fields) do
    local value = build[field]
    if value == vim.NIL then
      value = nil
    end
    if not vim.deep_equal(value, profile[field]) then
      return false
    end
  end
  return true
end

function M.snapshot(client)
  local build = (((client.settings or {}).texlab or {}).build or {})
  local profiles = require('tex-tools.config').options.build.profiles
  local available = M.names()
  local selected = require('tex-tools.build').state(client).compiler_profile
  if not selected or not profiles[selected] or not matches(build, profiles[selected]) then
    selected = nil
    for _, name in ipairs(available) do
      if matches(build, profiles[name]) then
        selected = name
        break
      end
    end
  end
  return {
    profile = selected,
    executable = build.executable or 'latexmk',
    args = build.args and vim.deepcopy(build.args) or nil,
    profiles = available,
  }
end

function M.select(name)
  vim.validate('name', name, 'string', true)
  local client, err = require('tex-tools.lsp').client()
  if not client then
    return false, err
  end
  if name == nil then
    return true, M.snapshot(client)
  end
  local manager = require('tex-tools.build')
  local state = manager.state(client)
  if manager.active(client) or state.cleaning then
    return false, 'Wait for compilation or cleaning to finish before switching compiler profiles'
  end
  local profiles = require('tex-tools.config').options.build.profiles
  local available = M.names()
  if #available == 0 then
    return false, 'No compiler profiles configured; set build.profiles in setup()'
  end
  if name == 'toggle' then
    local current = M.snapshot(client).profile
    local index = 0
    for candidate, profile in ipairs(available) do
      if profile == current then
        index = candidate
        break
      end
    end
    name = available[index % #available + 1]
  end
  local profile = profiles[name]
  if not profile then
    return false, 'Unknown compiler profile: ' .. name .. '; available: ' .. table.concat(available, ', ')
  end
  if vim.fn.executable(profile.executable) ~= 1 then
    return false, 'Compiler executable not found or not executable: ' .. profile.executable
  end
  local previous = client.settings
  local settings = vim.deepcopy(previous or {})
  settings.texlab = settings.texlab or {}
  settings.texlab.build = settings.texlab.build or {}
  -- Lists are replaced whole. Omitted output overrides are cleared so the
  -- previous backend's directories and job filename cannot leak into this one.
  for _, field in ipairs(require('tex-tools.config').profile_fields) do
    settings.texlab.build[field] = vim.deepcopy(profile[field])
  end
  client.settings = settings
  local ok, accepted = pcall(client.notify, client, 'workspace/didChangeConfiguration', { settings = settings })
  if not ok or not accepted then
    client.settings = previous
    return false, ok and 'texlab rejected the configuration change' or tostring(accepted)
  end
  state.compiler_profile = name
  return true, M.snapshot(client)
end

function M.command(name)
  local ok, snapshot = M.select(name)
  if not ok then
    return false, snapshot
  end
  local label = snapshot.profile and (snapshot.profile .. ' (' .. snapshot.executable .. ')')
    or (snapshot.executable .. ' (texlab settings)')
  vim.notify('Compiler: ' .. label, vim.log.levels.INFO, { title = 'tex-tools' })
  return true, snapshot
end

return M
