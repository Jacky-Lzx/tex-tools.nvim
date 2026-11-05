-- Independent TeX -> transparent PNG workers. Only the display integration
-- depends on image-tools; compilation, cancellation and cache leases live here.
local M = {}
local jobs, queue, active, leases, results = {}, {}, 0, {}, {}
local uv = vim.uv
local pump

local function color(options)
  if options.foreground ~= 'auto' then
    return options.foreground
  end
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  return string.format('#%06x', normal.fg or (vim.o.background == 'dark' and 0xffffff or 0x000000))
end

function M.key(source, options)
  -- JSON preserves field boundaries without passing NUL bytes to Vimscript.
  return vim.fn.sha256(vim.json.encode({
    'tex-tools-formula-v1',
    source,
    options.preamble,
    options.latex,
    options.dvipng,
    tostring(options.density),
    color(options),
  }))
end

-- Inspect only bounded PNG metadata; image-tools independently validates the
-- complete image before upload. Never read arbitrary-size converter output.
local function metadata(path, options)
  local stat = uv.fs_stat(path)
  if not stat or stat.size > 32 * 1024 * 1024 then
    return nil, 'Invalid or oversized formula PNG'
  end
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then
    return nil, 'Cannot read formula PNG'
  end
  local header = uv.fs_read(fd, 24, 0)
  uv.fs_close(fd)
  if not header or #header ~= 24 or header:sub(1, 8) ~= '\137PNG\r\n\26\n' or header:sub(13, 16) ~= 'IHDR' then
    return nil, 'Formula renderer did not produce a PNG'
  end
  local function integer(offset)
    local a, b, c, d = header:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local width, height = integer(17), integer(21)
  if width < 1 or height < 1 or width > 16384 or height > 16384 or width * height > 64 * 1024 * 1024 then
    return nil, 'Formula PNG dimensions exceed limits'
  end
  return {
    path = path,
    width = width,
    height = height,
    display_size = {
      width = math.max(1, math.floor(width * 180 / options.density + 0.5)),
      height = math.max(1, math.floor(height * 180 / options.density + 0.5)),
    },
  }
end

local function acquire(image)
  leases[image.path] = (leases[image.path] or 0) + 1
  local released = false
  local result = vim.deepcopy(image)
  result.release = function()
    if released then
      return
    end
    released = true
    leases[image.path] = leases[image.path] - 1
    if leases[image.path] == 0 then
      leases[image.path] = nil
    end
  end
  return result
end

function M.clear(cache)
  local removed = 0
  for _, path in ipairs(vim.fn.glob(cache .. '/*.png', false, true)) do
    if not leases[path] and not jobs[path] and uv.fs_unlink(path) then
      results[path], removed = nil, removed + 1
    end
  end
  return removed
end

local function trim(options)
  local files = {}
  for _, path in ipairs(vim.fn.glob(options.cache .. '/*.png', false, true)) do
    local stat = uv.fs_stat(path)
    if stat then
      files[#files + 1] = { path = path, time = stat.mtime.sec, size = stat.size }
    end
  end
  table.sort(files, function(a, b)
    return a.time < b.time
  end)
  local excess = #files - options.max_cache_entries
  local bytes = 0
  for _, file in ipairs(files) do
    bytes = bytes + file.size
  end
  for _, file in ipairs(files) do
    if excess <= 0 and bytes <= options.max_cache_bytes then
      break
    end
    if not leases[file.path] and not jobs[file.path] and uv.fs_unlink(file.path) then
      results[file.path], excess = nil, excess - 1
      bytes = bytes - file.size
    end
  end
end

local function finish(job, err, image)
  if job.finished then
    return
  end
  job.finished = true
  if jobs[job.path] == job then
    jobs[job.path] = nil
  end
  if job.started then
    active = active - 1
  end
  if job.workspace then
    vim.fn.delete(job.workspace, 'rf')
  end
  if image then
    results[job.path] = image
  end
  for subscriber in pairs(job.subscribers) do
    if not subscriber.cancelled then
      subscriber.callback(err, image and acquire(image))
    end
  end
  trim(job.options)
  pump()
end

local function run(job, command, next_step)
  local ok, process = pcall(
    vim.system,
    command,
    { cwd = job.workspace, text = true, timeout = job.options.timeout, env = { openin_any = 'p', openout_any = 'p' } },
    function(result)
      vim.schedule(function()
        job.process = nil
        if job.cancelled then
          finish(job)
          return
        end
        if result.code ~= 0 then
          finish(
            job,
            'Formula rendering failed ('
              .. vim.fs.basename(command[1])
              .. '): '
              .. vim.trim((result.stderr or '') .. '\n' .. (result.stdout or '')):sub(-4096)
          )
        else
          next_step()
        end
      end)
    end
  )
  if ok then
    job.process = process
  else
    finish(job, tostring(process))
  end
end

local function start(job)
  job.started, active = true, active + 1
  local options = job.options
  local cached = metadata(job.path, options)
  if cached then
    finish(job, nil, cached)
    return
  end
  for _, tool in ipairs({ options.latex, options.dvipng }) do
    if vim.fn.executable(tool) ~= 1 then
      finish(job, 'Formula rendering requires ' .. tool)
      return
    end
  end
  vim.fn.mkdir(options.cache, 'p')
  job.workspace = vim.fn.tempname() .. '-tex-tools-formula'
  local ok, err = pcall(function()
    assert(uv.fs_mkdir(job.workspace, 448))
    vim.fn.writefile(
      vim.split(
        table.concat({
          '\\documentclass{article}',
          options.preamble,
          '\\pagestyle{empty}',
          '\\begin{document}',
          '\\noindent',
          job.source,
          '\\end{document}',
        }, '\n'),
        '\n'
      ),
      job.workspace .. '/formula.tex'
    )
  end)
  if not ok then
    finish(job, tostring(err))
    return
  end
  run(
    job,
    { options.latex, '-no-shell-escape', '-interaction=nonstopmode', '-halt-on-error', 'formula.tex' },
    function()
      local rgb = {}
      for component in job.color:gmatch('%x%x') do
        rgb[#rgb + 1] = string.format('%.6f', tonumber(component, 16) / 255)
      end
      local output = job.workspace .. '/formula.png'
      run(job, {
        options.dvipng,
        '--nogs',
        '--norawps',
        '-T',
        'tight',
        '-D',
        tostring(options.density),
        '-bg',
        'Transparent',
        '-fg',
        'rgb ' .. table.concat(rgb, ' '),
        '-p',
        '1',
        '-l',
        '1',
        '-o',
        output,
        'formula.dvi',
      }, function()
        local image, error_message = metadata(output, options)
        if not image then
          finish(job, error_message)
          return
        end
        local staging = job.path .. '.' .. tostring(uv.hrtime()) .. '.tmp'
        local copied, copy_err = uv.fs_copyfile(output, staging)
        local renamed, rename_err
        if copied then
          renamed, rename_err = uv.fs_rename(staging, job.path)
        end
        uv.fs_unlink(staging)
        if not renamed then
          finish(job, tostring(copy_err or rename_err))
          return
        end
        image.path = job.path
        finish(job, nil, image)
      end)
    end
  )
end

pump = function()
  while #queue > 0 do
    local job = queue[1]
    if job.cancelled then
      table.remove(queue, 1)
      finish(job)
    elseif active < job.options.concurrency then
      table.remove(queue, 1)
      local ok, err = pcall(start, job)
      if not ok then
        finish(job, tostring(err))
      end
    else
      break
    end
  end
end

function M.prepare(source, options, callback)
  local path = options.cache .. '/' .. M.key(source, options) .. '.png'
  local job = jobs[path]
  if not job or job.cancelled then
    job = { path = path, source = source, color = color(options), options = vim.deepcopy(options), subscribers = {} }
    jobs[path], queue[#queue + 1] = job, job
  end
  local subscriber = { callback = callback }
  job.subscribers[subscriber] = true
  vim.schedule(pump)
  return function()
    if subscriber.cancelled then
      return
    end
    subscriber.cancelled = true
    job.subscribers[subscriber] = nil
    if not job.finished and not next(job.subscribers) then
      job.cancelled = true
      if job.process then
        pcall(job.process.kill, job.process, 15)
      else
        vim.schedule(pump)
      end
    end
  end
end

return M
