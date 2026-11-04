-- Real Neovim TUI, TeX compilation and image-tools public API integration.
-- Run through image-tools tests/tui/run.py with IMAGE_TOOLS_TEX_ROOT set.
local root, temporary = assert(vim.env.IMAGE_TOOLS_ROOT), assert(vim.env.IMAGE_TOOLS_TEST_TMP)
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(assert(vim.env.IMAGE_TOOLS_TEX_ROOT))
if vim.env.IMAGE_TOOLS_PARSER_ROOT then
  vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_PARSER_ROOT)
end
if vim.env.TEX_TOOLS_TEST_PARSER then
  vim.treesitter.language.add('latex', { path = vim.env.TEX_TOOLS_TEST_PARSER })
end
vim.o.termguicolors, vim.o.swapfile = true, false
local image, tex = require('image_tools'), require('tex-tools')
local configured = vim.env.TEX_TOOLS_CONFIGURED_TEST == '1'
if not configured then
  image.setup({
    position = 'bottom_right',
    right_padding = tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0,
    transport = vim.env.IMAGE_TOOLS_TEST_TRANSPORT,
    cache = temporary .. '/images',
    auto_preview_delay = 0,
  })
  tex.setup({
    formula_preview = { enabled = true, delay = 0, cache = temporary .. '/formulas', foreground = '#cad3f5' },
  })
end
vim.cmd('enew!')
vim.api.nvim_buf_set_name(0, temporary .. '/formula.tex')
vim.bo.filetype = 'tex'
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '$$', '\\frac{a}{b} + \\sqrt{x}', '$$', 'outside', 'image below' })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local scrollbar
if vim.env.IMAGE_TOOLS_UI_ROOT then
  vim.opt.rtp:prepend(vim.env.IMAGE_TOOLS_UI_ROOT)
  scrollbar = require('ui_tools.scrollbar')
  vim.api.nvim_buf_set_lines(0, -1, -1, false, vim.fn['repeat']({ 'scrollbar fixture' }, 100))
  scrollbar.setup({ handle = ' ', blend = 100, cursor = true, cursor_char = '●' })
end
local function move(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {})
end
local deadline, step, original_win, original_path, original_source, original_tick = vim.uv.hrtime() + 12e9, 1
original_source = vim.api.nvim_buf_get_lines(0, 0, -1, false)
original_tick = vim.api.nvim_buf_get_changedtick(0)
local function poll()
  local ok, err = pcall(function()
    assert(vim.uv.hrtime() < deadline, 'TeX formula TUI timed out: ' .. vim.inspect(tex.formula_info()))
    local info = tex.formula_info()
    local win = info.window
    if win then
      local padding = math.max(tonumber(vim.env.IMAGE_TOOLS_TEST_RIGHT_PADDING) or 0, scrollbar and 1 or 0)
      assert(
        vim.api.nvim_win_get_position(win)[2] + vim.api.nvim_win_get_width(win) + 2 == vim.o.columns - padding,
        'Formula float did not inherit image-tools padding'
      )
      if scrollbar then
        local left = vim.api.nvim_win_get_position(win)[2]
        local right = left + vim.api.nvim_win_get_width(win) + 2
        for _, bar in pairs(scrollbar.bars) do
          local bar_left = vim.api.nvim_win_get_position(bar.win)[2]
          assert(
            right <= bar_left or left >= bar_left + vim.api.nvim_win_get_width(bar.win),
            'Scrollbar overlaps TeX formula'
          )
        end
      end
    end
    if step == 1 and win then
      assert(info.stage == 'ready')
      assert(not image.status().window, 'image-tools still owns LaTeX formula detection')
      assert(vim.deep_equal(original_source, vim.api.nvim_buf_get_lines(0, 0, -1, false)))
      assert(original_tick == vim.api.nvim_buf_get_changedtick(0), 'Preview edited the source')
      if configured then
        local mapping = vim.fn.maparg((vim.g.mapleader or '\\') .. 'si', 'n', false, true)
        assert(type(mapping.callback) == 'function', 'Configured preview mapping missing')
        mapping.callback()
        assert(tex.formula_info().window == win, 'Configured preview mapping bypassed tex-tools')
      end
      original_win, original_path = win, info.path
      move(1)
      move(3)
      assert(tex.formula_info().window == original_win, 'Movement inside formula recreated it')
      move(4)
      assert(not tex.formula_info().window, 'Leaving formula retained pixels')
      move(2)
      step = 2
    elseif step == 2 and win then
      assert(image.status().terminal_cache.uploads == 1, 'Returning retransmitted cached pixels')
      vim.api.nvim_input(vim.keycode('A + c + d + e<Esc>'))
      step = 3
    elseif step == 3 and win and info.source and info.source:find('+ e', 1, true) then
      assert(info.path ~= original_path, 'Continuous input retained old formula pixels')
      assert(image.status().terminal_cache.uploads == 2, 'Continuous input did not replace the formula')
      vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'unclosed' })
      vim.api.nvim_exec_autocmds('TextChanged', {})
      assert(not tex.formula_info().window, 'Incomplete formula retained its float')
      vim.api.nvim_buf_set_lines(0, 1, 3, false, { '\\frac{a}{b} + \\sqrt{x}', '$$' })
      vim.api.nvim_exec_autocmds('TextChanged', {})
      step = 4
    elseif step == 4 and win then
      assert(info.path == original_path, 'Restoring the formula did not reuse the compiled PNG')
      vim.cmd('vsplit')
      move(2)
      step = 5
    elseif step == 5 and win then
      assert(image.status().terminal_cache.uploads == 2, 'A split re-uploaded shared pixels')
      vim.cmd('close')
      move(2)
      step = 6
    elseif step == 6 and win then
      vim.api.nvim_buf_set_lines(0, 4, 5, false, { '\\includegraphics{' .. original_path .. '}' })
      move(5)
      step = 7
    elseif step == 7 and image.status().window then
      assert(not tex.formula_info().window, 'Image reference retained the formula float')
      assert(image.status().terminal_cache.uploads == 2, 'Image reference did not share generated PNG pixels')
      image.close()
      tex.close_formula_preview()
      if configured then
        local mapping = vim.fn.maparg((vim.g.mapleader or '\\') .. 'ui', 'n', false, true)
        assert(type(mapping.callback) == 'function', 'Configured toggle mapping missing')
        mapping.callback()
        assert(not image.status().auto_preview and not tex.formula_info().enabled, 'Toggle did not disable both owners')
        mapping.callback()
        assert(image.status().auto_preview and tex.formula_info().enabled, 'Toggle did not enable both owners')
        image.close()
        tex.close_formula_preview()
      end
      local result = { math = true, lifecycle = true, shared = true, cache = image.status().terminal_cache }
      vim.fn.writefile({ vim.json.encode(result) }, temporary .. '/result.json')
      vim.cmd('qa!')
      return
    end
    vim.defer_fn(poll, 30)
  end)
  if not ok then
    vim.fn.writefile(
      { tostring(err), vim.inspect(tex.formula_info()), vim.inspect(image.status()) },
      temporary .. '/error.txt'
    )
    vim.cmd('cquit')
  end
end
vim.defer_fn(poll, 30)
