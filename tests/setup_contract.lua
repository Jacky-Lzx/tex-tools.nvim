vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require('tex-tools')
local options = { mappings = false, conceal = false, formula_preview = false, image_preview = false }
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), 'setup mutated caller configuration')
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), 'setup(false) must reject an invalid configuration type')
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), 'Invalid setup replaced commands')
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), 'Invalid setup replaced handlers')
plugin.setup(caller)
assert(#vim.api.nvim_get_autocmds({}) == #handlers, 'Repeated setup duplicated automatic handlers')
print('tex-tools.nvim: setup input isolation, invalid configuration and registration lifetime passed')

local api = vim.api
local buf = api.nvim_get_current_buf()
local original = function() end
vim.keymap.set('n', '<Plug>(TexToolsOutline)', original, { buffer = buf })
vim.bo.filetype = 'tex'
assert(vim.fn.exists(':TexToolsInfo') == 2)
local handlers = api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, { formula_preview = { delay = -1 } }))
assert(vim.deep_equal(handlers, api.nvim_get_autocmds({})))
local replacement = function() end
vim.keymap.set('i', '<Plug>(TexToolsSmartEnter)', replacement, { buffer = buf })
local custom = function() end
api.nvim_buf_create_user_command(buf, 'TexToolsInfo', custom, { force = true })
local text = api.nvim_buf_get_lines(buf, 0, -1, false)
plugin.dispose()
plugin.dispose()
vim.wait(30, function()
  return false
end)
assert(vim.fn.maparg('<Plug>(TexToolsOutline)', 'n', false, true).callback == original)
assert(vim.fn.maparg('<Plug>(TexToolsSmartEnter)', 'i', false, true).callback == replacement)
assert(vim.fn.exists(':TexToolsInfo') == 2, 'Disposal removed a replacement command')
assert(vim.fn.exists(':TexToolsPreview') == 0)
assert(vim.fn.exists('#TexToolsFormula') == 0 and vim.fn.exists('#TexToolsInverseTracking') == 0)
assert(vim.deep_equal(text, api.nvim_buf_get_lines(buf, 0, -1, false)))
api.nvim_buf_del_user_command(buf, 'TexToolsInfo')
plugin.setup(caller)
assert(vim.fn.exists(':TexToolsPreview') == 2)
plugin.dispose()

local build = require('tex-tools.build')
local calls = 0
local client = {
  id = 998,
  name = 'texlab',
  initialized = false,
  handlers = {
    ['window/logMessage'] = function()
      calls = calls + 1
    end,
  },
}
build.attach(client)
local old = client.handlers['window/logMessage']
local replacement = function(...)
  return old(...)
end
client.handlers['window/logMessage'] = replacement
build.dispose()
assert(client.handlers['window/logMessage'] == replacement)
build.attach(client)
local state = build.state(client)
state.output_lines = {}
old(nil, { type = vim.lsp.protocol.MessageType.Log, message = 'stale' }, {}, {})
assert(#state.output_lines == 0 and calls == 1, 'Captured stale handler reactivated after setup')
plugin.dispose()
