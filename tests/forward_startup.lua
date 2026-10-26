return function(h)
  h.test('forward search preserves early keypresses and their buffer across LspAttach', function()
    local config = require('tex-tools.config')
    local clients, requests, opened, notices, timers = {}, {}, {}, {}, {}
    local get_clients, defer, notify = vim.lsp.get_clients, vim.defer_fn, vim.notify
    local viewer = require('tex-tools.viewer')
    local show = viewer.show_location
    local forward = require('tex-tools').forward_search
    vim.lsp.get_clients = function()
      return clients
    end
    vim.defer_fn = function(callback, delay)
      h.eq(10000, delay)
      timers[#timers + 1] = callback
    end
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    viewer.show_location = function(_, result, position)
      opened[#opened + 1] = { result = result, position = position }
      return true
    end
    local client = {
      name = 'texquill',
      initialized = true,
      server_capabilities = { executeCommandProvider = { commands = { 'latex.forwardSearch' } } },
      request = function(_, method, params, callback, bufnr)
        requests[#requests + 1] = { method = method, params = params, bufnr = bufnr }
        callback(nil, { locations = {} })
        return true, #requests
      end,
    }
    local serial = 0
    local function buffer()
      clients = {}
      local bufnr = h.buffer('章节 test\nsecond line')
      serial = serial + 1
      vim.api.nvim_buf_set_name(bufnr, '/private/tmp/tex-tools-early-forward-' .. serial .. '.tex')
      vim.bo.modified = false
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      return bufnr
    end
    local function attach(bufnr)
      vim.api.nvim_exec_autocmds('LspAttach', { buffer = bufnr or 0, data = { client_id = 1 } })
    end
    local ok, err = xpcall(function()
      config.setup({ lsp = 'texquill' })
      local bufnr = buffer()
      h.eq(true, forward())
      h.eq(1, #timers)
      clients = { { name = 'texlab', initialized = true } }
      attach()
      h.eq(0, #requests)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      -- LspAttach may arrive after the user has switched to another buffer.
      h.buffer('other buffer')
      clients = { client }
      attach(bufnr)
      h.eq(1, #requests)
      h.eq(bufnr, requests[1].bufnr)
      h.eq('latex.forwardSearch', requests[1].params.command)
      h.eq({ line = 0, character = 2 }, requests[1].params.arguments[1].position)
      h.eq(requests[1].params.arguments[1], opened[1].position)
      timers[1]()
      h.eq(0, #notices)

      bufnr = buffer()
      forward()
      vim.api.nvim_win_set_cursor(0, { 2, 3 })
      forward()
      h.eq(2, #timers)
      clients = { client }
      attach()
      h.eq(2, #requests)
      h.eq({ line = 1, character = 3 }, requests[2].params.arguments[1].position)
      attach()
      h.eq(2, #requests)

      bufnr = buffer()
      forward()
      vim.api.nvim_buf_delete(bufnr, { force = true })
      timers[3]()
      h.eq(0, #notices)
      buffer()
      forward()
      timers[4]()
      h.eq(1, #notices)
      assert(notices[1]:find('did not attach', 1, true))
      clients = { client }
      attach()
      h.eq(2, #requests)

      client.initialized = false
      buffer()
      clients = { client }
      forward()
      h.eq(2, #requests)
      client.initialized = true
      attach()
      h.eq(3, #requests)
    end, debug.traceback)
    for _, callback in ipairs(timers) do
      callback()
    end
    vim.lsp.get_clients, vim.defer_fn, vim.notify = get_clients, defer, notify
    viewer.show_location = show
    config.setup()
    assert(ok, err)
  end)
end
