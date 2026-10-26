return function(h)
  local config, viewer = require('tex-tools.config'), require('tex-tools.viewer')
  local pdf, source = '/project/引号 " and spaces/paper.pdf', "/project/章节 ' quoted.tex"
  local position = { uri = vim.uri_from_fname(source), position = { line = 11, character = 0 } }
  local result = { pdfUri = vim.uri_from_fname(pdf), locations = { { page = 3, x = 48.5, y = 323.75 } } }
  local function check(name, fn)
    h.test('Skim: ' .. name, function()
      local system, notify, executable = vim.system, vim.notify, vim.fn.executable
      local calls, notices, responses = {}, {}, {}
      config.setup({ lsp = 'texquill', viewer = { method = 'skim', focus = false } })
      vim.fn.executable = function()
        return 1
      end
      vim.system = function(argv, options, callback)
        h.eq(10000, options.timeout)
        calls[#calls + 1] = argv
        local response = responses[#calls] or { code = 0 }
        if response.throw then
          error(response.throw)
        end
        callback(response)
        return {}
      end
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      local ok, err = xpcall(function()
        fn(calls, notices, responses)
        vim.wait(20, function()
          return false
        end)
      end, debug.traceback)
      vim.system, vim.notify, vim.fn.executable = system, notify, executable
      config.setup()
      assert(ok, err)
    end)
  end
  local function settle()
    vim.wait(20, function()
      return false
    end)
  end
  for _, focus in ipairs({ false, true }) do
    check('focus=' .. tostring(focus) .. ' controls launch and final activation', function(calls, notices)
      config.options.viewer.focus = focus
      h.eq(true, viewer.show_location({}, result, position))
      settle()
      local launch = focus and { 'open', '-a', 'Skim', pdf } or { 'open', '-g', '-a', 'Skim', pdf }
      h.eq(launch, calls[1])
      h.eq(2, #calls)
      h.eq('osascript', calls[2][1])
      h.eq({ pdf, '3', '48.5', '323.75', source, '12', tostring(focus) }, vim.list_slice(calls[2], 4))
      local script = calls[2][3]
      assert(script:find('if shouldFocus then activate', 1, true))
      assert(script:find('repeat 50 times', 1, true))
      assert(script:find('media bounds', 1, true))
      assert(script:find('go theDoc to TeX line', 1, true))
      assert(not script:find(pdf, 1, true) and not script:find(source, 1, true))
      h.eq({}, notices)
    end)
  end
  check('launch failure stops before positioning', function(calls, notices, responses)
    responses[1] = { code = 1, stderr = 'Skim launch failed' }
    h.eq(true, viewer.show_location({}, result, position))
    settle()
    h.eq(1, #calls)
    h.eq({ 'Skim launch failed' }, notices)
  end)
  check('positioning failure reports its native error', function(_, notices, responses)
    responses[2] = { code = 1, stderr = 'Skim did not finish opening the PDF' }
    h.eq(true, viewer.show_location({}, result, position))
    settle()
    h.eq({ 'Skim did not finish opening the PDF' }, notices)
  end)
  check('spawn failures are returned or reported', function(_, notices, responses)
    responses[1] = { throw = 'Cannot spawn viewer' }
    local ok, err = viewer.show_location({}, result, position)
    h.eq(false, ok)
    assert(err:find('Cannot spawn viewer', 1, true))
    responses[1], responses[2], responses[3] = nil, nil, { throw = 'Cannot spawn AppleScript' }
    h.eq(true, viewer.show_location({}, result, position))
    settle()
    assert(notices[1]:find('Cannot spawn AppleScript', 1, true))
  end)
  check('missing result or executables fails before launching', function(calls)
    h.eq(false, viewer.show_location({}, { pdfUri = result.pdfUri, locations = {} }, position))
    vim.fn.executable = function()
      return 0
    end
    h.eq(false, viewer.show_location({}, result, position))
    h.eq({}, calls)
  end)
end
