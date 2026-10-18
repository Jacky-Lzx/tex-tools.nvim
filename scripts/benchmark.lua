-- Run with nvim --clean --headless -l scripts/benchmark.lua.
-- TEX_TOOLS_TEST_PARSER: optional path to latex.so.
-- TEX_TOOLS_BENCH_RTP: alternate checkout for before/after comparisons.
-- TEX_TOOLS_BENCH: runtime (default), conceal, stress, long-line, or load.
-- TEX_TOOLS_BENCH_SIZE: runtime line count or long-line formula count.
vim.opt.runtimepath:prepend(vim.env.TEX_TOOLS_BENCH_RTP or vim.fn.getcwd())
vim.opt.shadafile = 'NONE'
vim.opt.swapfile = false
-- Keep the headless screen's actual geometry. Changing lines/columns without
-- an attached UI can leave Neovim's screen grid inconsistent during redraw.
local mode = vim.env.TEX_TOOLS_BENCH or 'runtime'
local size = tonumber(vim.env.TEX_TOOLS_BENCH_SIZE)
local parser = vim.env.TEX_TOOLS_TEST_PARSER

local function timed(fn)
  local start = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - start) / 1e6
end

local function sample(fn, count, returned_time)
  local times = {}
  for i = 1, count do
    times[i] = returned_time and fn(i) or timed(function()
      fn(i)
    end)
  end
  table.sort(times)
  return { median = times[math.ceil(count / 2)], p95 = times[math.ceil(count * 0.95)] }
end

local function report(result)
  result.mode = mode
  result.neovim = tostring(vim.version())
  -- Write machine-readable output without scrolling Neovim's message grid.
  io.stdout:write(vim.json.encode(result), '\n')
  io.stdout:flush()
end

local tex, result = nil, {}
result.require_ms = timed(function()
  tex = require('tex-tools')
end)
result.setup_ms = timed(function()
  tex.setup()
end)
result.attach_ms = timed(function()
  vim.bo.filetype = 'tex'
end)
if mode == 'load' then
  result.modules = {}
  for name in pairs(package.loaded) do
    if name:match('^tex%-tools') then
      result.modules[#result.modules + 1] = name
    end
  end
  table.sort(result.modules)
  report(result)
  vim.cmd('qa!')
end

assert(
  pcall(vim.treesitter.language.add, 'latex', parser and { path = parser } or {}),
  'Install the latex parser or set TEX_TOOLS_TEST_PARSER'
)
if mode == 'runtime' then
  local block = {
    '\\section{Example heading}',
    'Some ordinary prose with words and references \\ref{eq:one}.',
    '$x_i^2 + \\alpha + \\frac{a}{b} \\leq \\infty$',
    '\\begin{itemize}',
    '\\item First entry with \\textbf{bold} and --- punctuation.',
    '\\item Second entry with a formula $y + \\beta$.',
    '\\end{itemize}',
    '',
  }
  for _, count in ipairs(size and { size } or { 1000, 10000, 50000 }) do
    local lines = {}
    for i = 1, count do
      lines[i] = block[(i - 1) % #block + 1]
    end
    vim.cmd.enew({ bang = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = 'tex'
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    result = { lines = count, bytes = vim.api.nvim_buf_get_offset(0, count) }
    result.first_context_ms = timed(function()
      assert(tex.in_math())
    end)
    result.context_ms = sample(function()
      assert(tex.in_math())
    end, 2000)
    result.context_pair_ms = sample(function()
      tex.in_comment()
      assert(tex.in_math())
    end, 2000)
    result.edit_context_ms = sample(function(i)
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { block[2] .. string.rep(' ', i % 2) })
      assert(tex.in_math())
    end, 40)
    result.nearby_navigation_ms = sample(function()
      vim.api.nvim_win_set_cursor(0, { 3, 2 })
      assert(tex.jump_section(1))
    end, 100)
    result.first_outline_ms = timed(function()
      assert(tex.outline_entries())
    end)
    result.repeated_outline_ms = sample(function()
      assert(tex.outline_entries())
    end, 3)
    result.filtered_outline_ms = sample(function()
      assert(tex.outline_entries({ query = 'heading' }))
    end, 3)
    report(result)
    vim.api.nvim_buf_delete(0, { force = true })
    collectgarbage('collect')
  end
else
  assert(mode == 'conceal' or mode == 'stress' or mode == 'long-line', 'Unknown benchmark mode')
  vim.wo.wrap, vim.wo.conceallevel, vim.wo.concealcursor = false, 2, 'nc'
  local durations, register = {}, vim.api.nvim_set_decoration_provider
  vim.api.nvim_set_decoration_provider = function(ns, options)
    local render = options.on_win
    options.on_win = function(...)
      local args = { ... }
      local value
      durations[#durations + 1] = timed(function()
        value = render(unpack(args))
      end)
      return value
    end
    return register(ns, options)
  end
  local lines = {}
  if mode == 'long-line' then
    lines[1] = string.rep('$\\alpha+\\beta$ ', size or 3000)
  else
    for i = 1, size or 10000 do
      lines[i] = '$x_i + \\alpha + \\frac{a}{b}$ and \\textbf{bold} --- words'
    end
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.treesitter.get_parser(0, 'latex'):parse()
  tex.setup({ conceal = vim.env.TEX_TOOLS_BENCH_UNLIMITED == '1' and { max_line_length = 0 } or true })
  local function render()
    durations = {}
    vim.cmd.redraw({ bang = true })
    assert(#durations > 0, 'No decoration callback')
    local total = 0
    for _, duration in ipairs(durations) do
      total = total + duration
    end
    return total
  end
  result = { lines = #lines, bytes = vim.api.nvim_buf_get_offset(0, #lines), height = vim.api.nvim_win_get_height(0) }
  result.first_render_ms = render()
  result.cached_render_ms = sample(render, 100, true)
  if mode == 'conceal' or mode == 'stress' then
    result.scroll_ms = sample(function(i)
      vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
      vim.cmd('normal! zt')
      return render()
    end, 50, true)
  end
  if mode == 'stress' then
    result.edit_ms = sample(function(i)
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      vim.api.nvim_buf_set_lines(0, row, row + 1, false, { lines[1] .. string.rep(' ', i % 2) })
      vim.treesitter.get_parser(0, 'latex'):parse()
      return render()
    end, 20, true)
    result.replacements = {}
    for _, count in ipairs({ 100, 1000, 3000, 1 }) do
      local source = string.rep('$\\alpha+\\beta$ ', count)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { source })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.treesitter.get_parser(0, 'latex'):parse()
      result.replacements[#result.replacements + 1] = { bytes = #source, render_ms = render() }
      assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == source, 'Rendering changed the source')
    end
  end
  report(result)
end
vim.cmd('qa!')
