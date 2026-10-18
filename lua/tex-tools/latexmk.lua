-- Ask latexmk for its effective configuration; .latexmkrc is Perl, not a data file.
-- Called by project actions and coalesced LSP/buffer/configuration events,
-- never by redraw or cursor handlers.
local M = {}
local cache, clock = {}, 0
local values = {
  ['-r'] = true,
  ['-e'] = true,
  ['-outdir'] = true,
  ['-output-directory'] = true,
  ['-auxdir'] = true,
  ['-aux-directory'] = true,
  ['-out2dir'] = true,
  ['-jobname'] = true,
}
local flags = {
  ['-cd'] = true,
  ['-cd-'] = true,
  ['-norc'] = true,
  ['-emulate-aux-dir'] = true,
  ['-emulate-aux-dir-'] = true,
}

local function stamp(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { stat.size, stat.mtime, stat.ctime, stat.ino } or false
end

local function current(entry)
  for path, value in pairs(entry.files) do
    if not vim.deep_equal(value, stamp(path)) then
      return false
    end
  end
  return true
end

local function absolute(path, cwd)
  return vim.fs.normalize(
    vim.fs.abspath((path:match('^[/\\]') or path:match('^%a:')) and path or vim.fs.joinpath(cwd, path)),
    { expand_env = false }
  )
end

function M.resolve(build, cwd, main)
  if vim.fn.filereadable(main) ~= 1 then
    return nil
  end
  local executable = build.executable or 'latexmk'
  if vim.fn.executable(executable) ~= 1 then
    return nil
  end
  -- Preserve configuration/directory options, excluding compilation, cleanup,
  -- preview and watch operations. No user argument is interpreted by a shell.
  local argv, paths = { executable }, { main, vim.fn.exepath(executable) }
  for _, base in ipairs({ cwd, vim.uv.os_homedir() }) do
    paths[#paths + 1] = vim.fs.joinpath(base, '.latexmkrc')
    paths[#paths + 1] = vim.fs.joinpath(base, 'latexmkrc')
  end
  local args, index = build.args or {}, 1
  while index <= #args do
    local argument = args[index]:gsub('%%f', function()
      return main
    end)
    local name = argument:match('^%-%-(.+)')
    if name then
      argument = '-' .. name
    end
    local option, value = argument:match('^([^=]+)=(.*)$')
    if values[argument] and args[index + 1] then
      value = args[index + 1]:gsub('%%f', function()
        return main
      end)
      vim.list_extend(argv, { argument, value })
      if argument == '-r' then
        paths[#paths + 1] = absolute(value, cwd)
      end
      index = index + 1
    elseif option and values[option] then
      argv[#argv + 1] = argument
      if option == '-r' then
        paths[#paths + 1] = absolute(value, cwd)
      end
    elseif flags[argument] then
      argv[#argv + 1] = argument
    end
    index = index + 1
  end
  local env_rc = vim.env.LATEXMKRC
  if env_rc and env_rc ~= '' then
    paths[#paths + 1] = absolute(env_rc, cwd)
  end
  vim.list_extend(argv, { '-dir-report-only', main })
  local key = vim.json.encode({ argv, cwd, env_rc or '' })
  local entry = cache[key]
  clock = clock + 1
  if entry and current(entry) then
    entry.used = clock
    return entry.layout
  end
  local ok, result = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true }):wait(2000)
  end)
  local output = ok and result.code == 0 and result.stdout or ''
  local report_cwd = output:match("Latexmk: Cwd: '([^\n]*)'") or cwd
  local aux, out, final =
    output:match("Normalized aux dir, out dir, out2 dir:[\r\n]+%s*'([^\n]*)', '([^\n]*)', '([^\n]*)'")
  -- Older latexmk versions report only aux/out, with no separate final directory.
  if not aux then
    aux, out = output:match("Normalized aux dir, out dir:[\r\n]+%s*'([^\n]*)', '([^\n]*)'")
    final = out
  end
  local stem = output:match("Base name of generated files:[\r\n]+%s*'([^\n]*)'")
  local layout
  if aux and out and final and stem and stem ~= '' and not stem:find('[/\\]') then
    layout =
      { cwd = report_cwd, aux_dir = absolute(aux, report_cwd), pdf_dir = absolute(final, report_cwd), stem = stem }
  end
  -- Remember every rc file reported by latexmk, including system and -r files.
  local rc = output:match('Rc files read[^\n]*\n(.-)Latexmk:')
  for path in (rc or ''):gmatch('[^\r\n]+') do
    path = vim.trim(path)
    if path ~= '' and path ~= 'NONE' then
      paths[#paths + 1] = absolute(path, cwd)
    end
  end
  local files = {}
  for _, path in ipairs(paths) do
    if path ~= '' then
      files[path] = stamp(path)
    end
  end
  cache[key] = { files = files, layout = layout, used = clock }
  if vim.tbl_count(cache) > 64 then
    local oldest
    for candidate, item in pairs(cache) do
      if not oldest or item.used < cache[oldest].used then
        oldest = candidate
      end
    end
    cache[oldest] = nil
  end
  return layout
end

function M.config_file(path)
  for _, entry in pairs(cache) do
    if entry.files[path] ~= nil then
      return true
    end
  end
  return false
end

return M
