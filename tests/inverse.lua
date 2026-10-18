return function(h)
  local child_env = vim.fn.environ()
  child_env.VIMRUNTIME = nil
  local eq, inverse = h.eq, require('tex-tools.inverse')
  local directory, registry, processes, channels
  local repo = vim.fn.getcwd()
  local function check(name, fn)
    h.test('stable inverse: ' .. name, function()
      local original_directory, clients = inverse.directory, vim.lsp.get_clients
      inverse.unregister()
      directory = vim.fn.tempname() .. ' stable inverse'
      registry = directory .. '/registry'
      processes, channels = {}, {}
      vim.fn.mkdir(directory, 'p')
      inverse.directory = function()
        return registry
      end
      local ok, err = xpcall(fn, debug.traceback)
      for _, channel in ipairs(channels) do
        pcall(vim.fn.chanclose, channel)
      end
      for _, process in ipairs(processes) do
        process:kill(15)
        process:wait(1000)
      end
      vim.wait(20, function()
        return false
      end)
      inverse.unregister()
      inverse.directory, vim.lsp.get_clients = original_directory, clients
      vim.fn.delete(directory, 'rf')
      if not ok then
        error(err)
      end
    end)
  end
  local function records()
    return vim.fn.glob(registry .. '/*.json', false, true)
  end
  local function launch(name, file, root)
    local config = directory .. '/' .. name .. '.json'
    local ready = directory .. '/' .. name .. '.ready'
    local boot = directory .. '/boot.lua'
    vim.fn.writefile(
      vim.split(
        [[
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.TEX_TOOLS_TEST_CONFIG), '\n'))
vim.opt.runtimepath:prepend(config.repo)
vim.opt.swapfile = false
local inverse = require('tex-tools.inverse')
inverse.directory = function() return config.registry end
local buf = vim.fn.bufadd(config.file)
vim.fn.bufload(buf)
vim.api.nvim_set_current_buf(buf)
vim.bo.filetype = 'tex'
require('tex-tools').setup({ mappings = false })
-- Only the integration fixture supplies fake project roots; sockets/RPC are real.
local clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
  if opts and opts.name == 'texlab' then return {{name='texlab', config={root_dir=config.root}}} end
  return clients(opts)
end
vim.wait(1000, function() return vim.v.servername ~= '' and vim.fn.filereadable(config.registry .. '/' .. vim.fn.sha256(vim.v.servername .. ':' .. vim.fn.getpid()) .. '.json') == 1 end, 10)
vim.fn.writefile({ vim.v.servername }, config.ready)
]],
        '\n',
        { plain = true }
      ),
      boot
    )
    vim.fn.writefile(
      { vim.json.encode({ repo = repo, registry = registry, file = file, root = root, ready = ready }) },
      config
    )
    local environment = vim.tbl_extend('force', child_env, { TEX_TOOLS_TEST_CONFIG = config })
    local process = vim.system(
      { vim.fn.exepath('nvim'), '--clean', '--headless', '-i', 'NONE', '-n', '-S', boot },
      { text = true, env = environment, clear_env = true }
    )
    processes[#processes + 1] = process
    if not vim.wait(5000, function()
      return vim.fn.filereadable(ready) == 1
    end, 10) then
      local result = process:wait(1000)
      error('editor did not start: ' .. (result.stderr or '') .. (result.stdout or ''))
    end
    local server = vim.fn.readfile(ready)[1]
    local channel = vim.fn.sockconnect('pipe', server, { rpc = true })
    assert(channel > 0)
    channels[#channels + 1] = channel
    return channel
  end
  local function run_callback(callback, file, line)
    local argv = vim.deepcopy(callback.argv)
    argv[1], argv[#argv - 1], argv[#argv] = vim.fn.exepath('nvim'), tostring(line or 2), file
    local result
    vim.system(argv, { text = true, env = child_env, clear_env = true }, function(value)
      result = value
    end)
    assert(
      vim.wait(7000, function()
        return result ~= nil
      end, 10),
      'dispatcher timed out'
    )
    return result
  end
  local function current(channel)
    return vim.rpcrequest(
      channel,
      'nvim_exec_lua',
      'return {vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)}',
      {}
    )
  end
  local function file(path)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile({ 'first', 'second' }, path)
    return path
  end
  check('automatic registration is atomic, private, idempotent and cleaned up', function()
    local bufnr = h.buffer('content')
    vim.api.nvim_buf_set_name(bufnr, file(directory .. '/main.tex'))
    assert(vim.wait(1000, function()
      return #records() == 1
    end, 10))
    local path = records()[1]
    local record = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    eq(vim.v.servername, record.server)
    eq(vim.fn.getpid(), record.pid)
    eq('rw-------', vim.fn.getfperm(path))
    eq('rwx------', vim.fn.getfperm(registry))
    local server = assert(inverse.register())
    eq(server, record.server)
    eq({ path }, records())
    eq(record.token, vim.json.decode(table.concat(vim.fn.readfile(path), '\n')).token)
    eq({}, vim.fn.glob(registry .. '/*.tmp', false, true))
    inverse.unregister()
    eq({}, records())
  end)
  check('scoring uses open buffers, project boundaries and session identity', function()
    local opened = file(directory .. '/project/main.tex')
    local bufnr = h.buffer('content')
    vim.api.nvim_buf_set_name(bufnr, opened)
    inverse.register()
    local record = vim.json.decode(table.concat(vim.fn.readfile(records()[1]), '\n'))
    vim.lsp.get_clients = function()
      return { { config = { root_dir = directory .. '/project' } } }
    end
    eq(2, inverse.score(opened, record.token).priority)
    eq(1, inverse.score(directory .. '/project/child.tex', record.token).priority)
    eq(nil, inverse.score(directory .. '/project-other/child.tex', record.token))
    eq(nil, inverse.score(opened, 'old-session-token'))
    local link = directory .. '/linked.tex'
    assert(vim.uv.fs_symlink(opened, link))
    eq(2, inverse.score(link, record.token).priority)
  end)
  check('same callback survives editor restart and opens a project child', function()
    local main = file(directory .. '/project/main.tex')
    local child = file(directory .. '/project/child 中文 \' " $().tex')
    local callback = assert(require('tex-tools').inverse_search_command('zathura'))
    inverse.unregister() -- the controller must not compete with the two editors
    local first = launch('first', main, directory .. '/project')
    local first_server = vim.rpcrequest(first, 'nvim_eval', 'v:servername')
    eq(0, run_callback(callback, child).code)
    eq({ child, { 2, 0 } }, current(first))
    vim.rpcnotify(first, 'nvim_command', 'qa!')
    if not vim.wait(3000, function()
      return #records() == 0
    end, 10) then
      local result = processes[1]:wait(500)
      error('exit left a session record: ' .. vim.inspect(result))
    end
    local second = launch('second', main, directory .. '/project')
    local second_server = vim.rpcrequest(second, 'nvim_eval', 'v:servername')
    assert(first_server ~= second_server)
    eq(0, run_callback(callback, child).code)
    eq({ child, { 2, 0 } }, current(second))
  end)
  check('routes to the owning instance, skips dead records and refuses unrelated files', function()
    local a, b = file(directory .. '/a/main.tex'), file(directory .. '/b/main.tex')
    local child = file(directory .. '/a/child.tex')
    local unrelated = file(directory .. '/other/main.tex')
    local callback = assert(require('tex-tools').inverse_search_command('zathura'))
    inverse.unregister()
    local first = launch('a', a, directory .. '/a')
    local second = launch('b', b, directory .. '/b')
    vim.fn.writefile({ '{broken' }, registry .. '/bad.json')
    vim.fn.writefile(
      { vim.json.encode({ pid = 2147483647, server = directory .. '/dead.sock', token = 'dead' }) },
      registry .. '/dead.json'
    )
    vim.fn.writefile(
      { vim.json.encode({ pid = vim.fn.getpid(), server = directory .. '/absent.sock', token = 'absent' }) },
      registry .. '/abce.json'
    )
    eq(0, run_callback(callback, child).code)
    eq({ child, { 2, 0 } }, current(first))
    eq({ b, { 1, 0 } }, current(second))
    eq(0, vim.fn.filereadable(registry .. '/dead.json'))
    eq(0, vim.fn.filereadable(registry .. '/abce.json'))
    local result = run_callback(callback, unrelated)
    eq(1, result.code)
    assert(result.stderr:find('No responsive Neovim session', 1, true))
    eq({ child, { 2, 0 } }, current(first))
    eq({ b, { 1, 0 } }, current(second))
    -- An already-open source outranks a workspace match in a newer instance.
    local third = launch('c', b, directory)
    eq(0, run_callback(callback, child).code)
    eq({ child, { 2, 0 } }, current(first))
    eq({ b, { 1, 0 } }, current(third))
  end)
  check('unresponsive sessions time out without losing their records', function()
    local target = file(directory .. '/project/main.tex')
    local callback = assert(require('tex-tools').inverse_search_command('zathura'))
    inverse.unregister()
    local editor = launch('responsive', target, directory .. '/project')
    local listener, accepted = vim.uv.new_pipe(false), {}
    local socket = directory .. '/hung.sock'
    assert(listener:bind(socket))
    listener:listen(8, function()
      local connection = vim.uv.new_pipe(false)
      listener:accept(connection)
      accepted[#accepted + 1] = connection
      connection:read_start(function() end)
    end)
    vim.fn.writefile(
      { vim.json.encode({ pid = vim.fn.getpid(), server = socket, token = 'hung' }) },
      registry .. '/affe.json'
    )
    local ok, err = xpcall(function()
      eq(0, run_callback(callback, target).code)
      eq({ target, { 2, 0 } }, current(editor))
      eq(1, vim.fn.filereadable(registry .. '/affe.json'))
    end, debug.traceback)
    for _, connection in ipairs(accepted) do
      connection:close()
    end
    listener:close()
    if not ok then
      error(err)
    end
  end)
end
