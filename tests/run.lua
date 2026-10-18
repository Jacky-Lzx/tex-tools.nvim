-- Run from the repository root: nvim --clean --headless -l tests/run.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.opt.hidden = true
vim.g.maplocalleader = ','

local parser_path = vim.env.TEX_TOOLS_TEST_PARSER
local parser_ok, parser_err = pcall(vim.treesitter.language.add, 'latex', parser_path and { path = parser_path } or {})
if not parser_ok then
  error('Install the latex parser or set TEX_TOOLS_TEST_PARSER to latex.so: ' .. tostring(parser_err))
end

local tex = require('tex-tools')
local objects = require('tex-tools.textobjects')
local tests, passed = {}, 0
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end
local function eq(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(('Expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end
local function buffer(text, ft)
  vim.cmd.enew({ bang = true })
  vim.bo.buftype = ''
  vim.bo.filetype = ft or 'tex'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n', { plain = true }))
  return vim.api.nvim_get_current_buf()
end
local function at(text, offset)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { row, col - 1 + (offset or 0) })
      return
    end
  end
  error('Fixture does not contain ' .. text)
end
local function content()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end
local function keys(input)
  vim.api.nvim_feedkeys(vim.keycode(input), 'xt', false)
end

tex.setup()

for _, expression in ipairs({ '$x+1$', '\\(x+1\\)', '$$x+1$$', '\\[x+1\\]' }) do
  test('math delimiters: ' .. expression, function()
    buffer('before ' .. expression .. ' after')
    at('x+1')
    eq(true, tex.in_math())
    at('before')
    eq(false, tex.in_math())
    at('after')
    eq(false, tex.in_math())
  end)
end

test('math environments and nested text/math', function()
  buffer('\\begin{align*}\n x + \\text{words $y$} \\\\\n\\end{align*}')
  at('x +')
  eq(true, tex.in_math())
  at('words')
  eq(false, tex.in_math())
  at('$y$', 1)
  eq(true, tex.in_math())
end)

test('comments suppress math inside formulas', function()
  buffer('\\[\nx % ignored $x$\n\\]')
  at('ignored')
  eq(true, tex.in_comment())
  eq(false, tex.in_math())
end)

test('escaped percent is not a comment', function()
  buffer('price \\% and $x$')
  at('price')
  eq(false, tex.in_comment())
  at('$x$', 1)
  eq(true, tex.in_math())
end)

for _, fixture in ipairs({ '\\iffalse\nignored $x$\n\\fi', '\\begin{comment}\nignored $x$\n\\end{comment}' }) do
  test('block comments: ' .. fixture:match('[^\n]+'), function()
    buffer(fixture)
    at('ignored')
    eq(true, tex.in_comment())
    eq(false, tex.in_math())
  end)
end

for _, name in ipairs({ 'verbatim', 'lstlisting', 'minted' }) do
  test('literal content is neither math nor comment: ' .. name, function()
    buffer(
      '\\begin{' .. name .. '}' .. (name == 'minted' and '{lua}' or '') .. '\n$x$ % literal\n\\end{' .. name .. '}'
    )
    at('literal')
    eq(false, tex.in_math())
    eq(false, tex.in_comment())
  end)
end

test('custom math environments and reset configuration', function()
  tex.setup({ math_environments = { 'mymath' } })
  buffer('\\begin{mymath*}\nx\n\\end{mymath*}')
  at('x')
  eq(true, tex.in_math())
  tex.setup()
  eq(false, tex.in_math())
end)

local nested = '\\begin{document}\n\\begin{itemize}\n\\item 中文\n\\end{itemize}\n\\end{document}'
test('innermost environment and paired rename', function()
  buffer(nested)
  at('中文')
  eq('itemize', tex.environment().name)
  eq(true, tex.rename_environment('enumerate'))
  eq(nested:gsub('itemize', 'enumerate'), content())
end)

test('same-line names with UTF-8 before markers', function()
  buffer('中文 \\begin{equation}x\\end{equation} 后文')
  at('}x', 1)
  eq(true, tex.rename_environment('align*'))
  eq('中文 \\begin{align*}x\\end{align*} 后文', content())
end)

test('star toggle round trip', function()
  buffer('\\begin{equation}\nx\n\\end{equation}')
  at('x')
  local original = content()
  eq(true, tex.toggle_environment_star())
  eq('equation*', tex.environment().name)
  eq(true, tex.toggle_environment_star())
  eq(original, content())
end)

test('one undo restores both names', function()
  buffer('\\begin{equation}\nx\n\\end{equation}')
  at('x')
  local original = content()
  -- Separate the fixture insertion from the user action's undo block.
  vim.cmd('let &undolevels = &undolevels')
  eq(true, tex.rename_environment('align'))
  vim.cmd.undo()
  eq(original, content())
end)

test('reject mismatched names without changing text', function()
  buffer('\\begin{equation}\nx\n\\end{align}')
  at('x')
  local original = content()
  eq(false, tex.rename_environment('gather'))
  eq(original, content())
end)

test('reject incomplete environment without changing text', function()
  buffer('\\begin{equation}\nx')
  at('x')
  local original = content()
  eq(false, tex.rename_environment('align'))
  eq(original, content())
end)

test('reject unsafe names and unmodifiable buffers', function()
  buffer('\\begin{equation}x\\end{equation}')
  at('}x', 1)
  eq(false, tex.rename_environment('align} injected'))
  vim.bo.modifiable = false
  eq(false, tex.toggle_environment_star())
  vim.bo.modifiable = true
end)

test('asynchronous rename refuses stale nodes', function()
  buffer('\\begin{equation}\nx\n\\end{equation}')
  at('x')
  local input, notify = vim.ui.input, vim.notify
  local callback
  vim.ui.input = function(_, cb)
    callback = cb
  end
  eq(true, tex.rename_environment())
  vim.ui.input = input
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'changed' })
  vim.notify = function() end
  callback('align')
  vim.notify = notify
  eq('equation', tex.environment().name)
end)

test('jump body to end and end to begin', function()
  buffer('\\begin{equation}\nx\n\\end{equation}')
  at('x')
  eq(true, tex.jump_environment())
  eq({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  eq(true, tex.jump_environment())
  eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
end)

test('environment range excludes options and marker lines', function()
  buffer('\\begin{itemize}[nosep]\n  \\item 中文\n\\end{itemize}')
  at('中文')
  eq({ 1, 0, 1, #'  \\item 中文' }, objects.environment_range(true))
  eq({ 0, 0, 2, #'\\end{itemize}' }, objects.environment_range(false))
end)

test('empty body has no inner text object', function()
  buffer('\\begin{equation}\\end{equation}')
  at('equation')
  eq(nil, objects.environment_range(true))
end)

for _, selection in ipairs({ 'inclusive', 'exclusive' }) do
  test('real operator text objects with UTF-8 and selection=' .. selection, function()
    vim.o.selection = selection
    buffer('prefix \\begin{quote}中文\\end{quote} suffix')
    at('中文')
    keys('yie')
    eq('中文', vim.fn.getreg('"'))
    keys('dae')
    eq('prefix  suffix', content())
    vim.o.selection = 'inclusive'
  end)
end

test('multiline inner yank', function()
  buffer('\\begin{quote}\nfirst\n中文\n\\end{quote}')
  at('first')
  keys('yie')
  eq('first\n中文', vim.fn.getreg('"'))
end)

test('no environment cancels pending operator', function()
  buffer('keep all of this')
  keys('die')
  eq('keep all of this', content())
end)

test('explicit buffer and position', function()
  local bufnr = buffer('$x$')
  buffer('outside')
  eq(true, tex.in_math({ bufnr = bufnr, pos = { 0, 1 } }))
  eq(false, tex.in_math({ bufnr = bufnr }))
end)

test('missing parser fails gracefully', function()
  local get_parser = vim.treesitter.get_parser
  vim.treesitter.get_parser = function()
    error('not installed')
  end
  local ok, err = tex.in_math()
  eq(false, ok)
  assert(err:find('parser unavailable', 1, true))
  eq(false, tex.rename_environment('align'))
  vim.treesitter.get_parser = get_parser
end)

test('setup attaches existing buffers and is idempotent', function()
  buffer('x')
  tex.setup()
  tex.setup()
  assert(vim.api.nvim_buf_get_commands(0, {}).TexToolsBuild)
  eq(2, #vim.api.nvim_get_autocmds({ group = 'TexTools' }))
  buffer('plain', 'plaintex')
  assert(vim.api.nvim_buf_get_commands(0, {}).TexToolsRenameEnvironment)
  buffer('local x = 1', 'lua')
  eq(nil, vim.api.nvim_buf_get_commands(0, {}).TexToolsBuild)
end)

test('disabled default mappings still provide Plug mappings', function()
  buffer('x')
  assert(vim.fn.maparg(',ler', 'n') ~= '')
  tex.setup({ mappings = false })
  eq('', vim.fn.maparg(',ler', 'n'))
  assert(vim.fn.maparg('<Plug>(TexToolsRenameEnvironment)', 'n') ~= '')
  tex.setup()
end)

test('preserve existing user mappings', function()
  buffer('x', 'lua')
  vim.keymap.set('n', ',ler', '<Nop>', { buffer = true })
  vim.bo.filetype = 'tex'
  eq('<Nop>', vim.fn.maparg(',ler', 'n'))
end)

test('texlab requests use the attached client and correct UTF-16 position', function()
  local bufnr = buffer('中文 x')
  vim.api.nvim_buf_set_name(bufnr, '/tmp/tex-tools-lsp-test.tex')
  vim.bo.modified = false
  at('x')
  local get_clients, notify = vim.lsp.get_clients, vim.notify
  local requests, messages = {}, {}
  local client = { offset_encoding = 'utf-16' }
  function client:request(method, params, callback, target)
    requests[#requests + 1] = { method, params, target }
    callback(nil, { status = 0 })
    return true, 42
  end
  vim.lsp.get_clients = function(filter)
    eq({ bufnr = bufnr, name = 'texlab' }, filter)
    return { client }
  end
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  eq(true, tex.build())
  eq(true, tex.forward_search())
  vim.lsp.get_clients, vim.notify = get_clients, notify
  eq('textDocument/build', requests[1][1])
  eq({ textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, requests[1][2])
  eq('textDocument/forwardSearch', requests[2][1])
  eq({ line = 0, character = 3 }, requests[2][2].position)
  eq(bufnr, requests[2][3])
  eq(2, #messages)
end)

test('no texlab fails gracefully', function()
  buffer('x')
  local get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return {}
  end
  eq(false, tex.build())
  eq(false, tex.forward_search())
  vim.lsp.get_clients = get_clients
end)

test('build saves modified content before sending the request', function()
  local bufnr = buffer('new content')
  local path = vim.fn.tempname() .. '.tex'
  vim.api.nvim_buf_set_name(bufnr, path)
  local get_clients, notify = vim.lsp.get_clients, vim.notify
  local called = false
  vim.lsp.get_clients = function()
    return {
      {
        request = function(_, method, _, callback)
          called = true
          eq('textDocument/build', method)
          eq(false, vim.bo[bufnr].modified)
          eq({ 'new content' }, vim.fn.readfile(path))
          callback(nil, { status = 0 })
          return true, 1
        end,
      },
    }
  end
  vim.notify = function() end
  local ok = tex.build()
  vim.lsp.get_clients, vim.notify = get_clients, notify
  vim.fn.delete(path)
  eq(true, ok)
  eq(true, called)
end)

test('save failure prevents a build request', function()
  local bufnr = buffer('unsaved content')
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. '.tex')
  vim.bo.readonly = true
  local get_clients = vim.lsp.get_clients
  local called = false
  vim.lsp.get_clients = function()
    return { {
      request = function()
        called = true
      end,
    } }
  end
  local ok = tex.build()
  vim.lsp.get_clients = get_clients
  vim.bo.readonly = false
  eq(false, ok)
  eq(false, called)
  eq(true, vim.bo[bufnr].modified)
end)

test('unnamed files do not send texlab requests', function()
  buffer('x')
  local get_clients = vim.lsp.get_clients
  local called = false
  vim.lsp.get_clients = function()
    return { {
      request = function()
        called = true
      end,
    } }
  end
  local ok = tex.build()
  vim.lsp.get_clients = get_clients
  eq(false, ok)
  eq(false, called)
end)

test('texlab errors, empty responses and rejected requests are handled', function()
  local bufnr = buffer('x')
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. '.tex')
  vim.bo.modified = false
  local get_clients, notify = vim.lsp.get_clients, vim.notify
  local messages = {}
  local client = {}
  vim.lsp.get_clients = function()
    return { client }
  end
  vim.notify = function(message, level)
    messages[#messages + 1] = { message, level }
  end
  function client:request(_, _, callback)
    callback({ message = 'server error' })
    return true, 1
  end
  local rpc_ok = tex.build()
  function client:request(_, _, callback)
    callback(nil, nil)
    return true, 2
  end
  local empty_ok = tex.build()
  function client:request()
    return false
  end
  local rejected_ok = tex.build()
  vim.lsp.get_clients, vim.notify = get_clients, notify
  eq(true, rpc_ok)
  eq({ 'server error', vim.log.levels.ERROR }, messages[1])
  eq(true, empty_ok)
  eq('Unexpected response from texlab', messages[2][1])
  eq(false, rejected_ok)
end)

dofile('tests/editing.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })
dofile('tests/list.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })
dofile('tests/enter.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })
dofile('tests/navigation.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })
dofile('tests/command.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })

dofile('tests/delimiter.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })

dofile('tests/repeat.lua')({ test = test, eq = eq, buffer = buffer, at = at, content = content, keys = keys })

dofile('tests/navigation_structures.lua')({
  test = test,
  eq = eq,
  buffer = buffer,
  at = at,
  content = content,
  keys = keys,
})

for _, entry in ipairs(tests) do
  local input, notify, get_clients, get_parser =
    vim.ui.input, vim.notify, vim.lsp.get_clients, vim.treesitter.get_parser
  local ok, err = xpcall(entry[2], debug.traceback)
  vim.cmd.stopinsert()
  vim.ui.input, vim.notify, vim.lsp.get_clients, vim.treesitter.get_parser = input, notify, get_clients, get_parser
  vim.o.selection = 'inclusive'
  if ok then
    passed = passed + 1
    print('PASS ' .. entry[1])
  else
    io.stderr:write('FAIL ' .. entry[1] .. '\n' .. err .. '\n')
  end
end
print(('%d/%d tests passed'):format(passed, #tests))
vim.cmd(passed == #tests and 'qa!' or 'cquit 1')
