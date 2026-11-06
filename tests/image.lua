return function(t)
  local test, eq, buffer, at = t.test, t.eq, t.buffer, t.at
  local tex = require('tex-tools')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/Figures', 'p')
  root = assert(vim.uv.fs_realpath(root))
  vim.fn.writefile({ 'image' }, root .. '/Figures/one.png')
  vim.fn.writefile({ 'image' }, root .. '/Figures/中文 image.png')
  local serial = 0
  local function setup(text)
    tex.setup({ mappings = true, image_preview = { delay = 0 }, formula_preview = { enabled = true, delay = 0 } })
    buffer(text)
    serial = serial + 1
    vim.api.nvim_buf_set_name(0, root .. '/note-' .. serial .. '.tex')
  end
  test('image preview resolves literal graphicspath and omitted extensions', function()
    setup('\\graphicspath{{Figures/}}\n\\includegraphics[width=2cm]{one}')
    at('one')
    local image = assert(tex.image_at())
    eq(root .. '/Figures/one.png', image.path)
    eq({ 1, 0, 1, #'\\includegraphics[width=2cm]{one}' }, image.range)
    assert(not package.loaded['image_tools.document.tex'], 'tex-tools imported image-tools syntax')
  end)
  test('image preview preserves multiline starred detokenize ranges', function()
    setup(
      '\\graphicspath{{Figures/}}\n\\includegraphics*\n[\n% comment\nwidth=2cm\n]\n{\\detokenize{中文 image.png}}\noutside'
    )
    for row = 2, 7 do
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      local image = assert(tex.image_at(), 'No image on row ' .. row)
      eq(root .. '/Figures/中文 image.png', image.path)
      eq(1, image.range[1])
      eq(6, image.range[3])
    end
    at('outside')
    eq(nil, tex.image_at())
  end)
  test('image preview excludes literal content definitions and dynamic paths', function()
    for _, text in ipairs({
      '% \\includegraphics{Figures/one.png}',
      '\\verb|\\includegraphics{Figures/one.png}|',
      '\\lstinline|\\includegraphics{Figures/one.png}|',
      '\\begin{verbatim}\n\\includegraphics{Figures/one.png}\n\\end{verbatim}',
      '\\newcommand{\\image}{\\includegraphics{Figures/one.png}}',
      '\\includegraphics{\\folder/one.png}',
      '\\includegraphics{Figures/one.png',
    }) do
      setup(text)
      at('one.png')
      eq(nil, tex.image_at())
    end
  end)
  test('image preview selects by cursor and keeps resolution live', function()
    setup('\\includegraphics{Figures/one.png} and \\includegraphics{Figures/中文 image.png}')
    at('中文')
    eq(root .. '/Figures/中文 image.png', assert(tex.image_at()).path)
    at('and')
    eq(root .. '/Figures/one.png', assert(tex.image_at()).path)
    tex.setup({ mappings = true, image_preview = { root = root .. '/Figures', max_lines = 1 } })
    buffer('\\includegraphics{one}')
    eq(root .. '/Figures/one.png', assert(tex.image_at()).path)
    buffer('\\includegraphics\n{one}')
    eq(nil, tex.image_at())
  end)
  test('unified preview chooses image or formula and claims only TeX buffers', function()
    local renderer, original = require('tex-tools.formula.render'), package.loaded.image_tools
    local prepare = renderer.prepare
    local requests, pending, releases = {}, {}, 0
    local ok, err = xpcall(function()
      package.loaded.image_tools = {
        close = function() end,
        float = function(request)
          local scratch = vim.api.nvim_create_buf(false, true)
          vim.bo[scratch].filetype = 'image-tools-test'
          vim.api.nvim_buf_delete(scratch, { force = true })
          requests[#requests + 1] = request
          local closed = false
          return {
            close = function()
              if not closed then
                closed = true
                request.on_close()
              end
            end,
            status = function()
              return { stage = 'ready', window = 123 }
            end,
          }
        end,
      }
      renderer.prepare = function(_, _, callback)
        pending[#pending + 1] = callback
        return function() end
      end
      setup('$x$ and \\includegraphics{Figures/one.png}\noutside')
      eq('tex-tools', vim.b.image_tools_preview_owner)
      at('one.png')
      assert(tex.preview())
      eq('image', tex.formula_info().kind)
      eq(root .. '/Figures/one.png', requests[1].path)
      at('x')
      assert(tex.preview())
      eq(1, #pending)
      pending[1](nil, {
        path = root .. '/formula.png',
        release = function()
          releases = releases + 1
        end,
      })
      eq('formula', tex.formula_info().kind)
      assert(not requests[1].is_valid(), 'old image retained selection authority')
      at('one.png')
      require('tex-tools.formula').refresh()
      eq('image', tex.formula_info().kind)
      eq(1, releases)
      at('outside')
      require('tex-tools.formula').refresh()
      eq(nil, tex.formula_info().window)
      tex.toggle_formula_preview()
      eq(nil, vim.b.image_tools_preview_owner)
      tex.toggle_formula_preview()
      eq('tex-tools', vim.b.image_tools_preview_owner)
      vim.bo.filetype = 'rust'
      eq(nil, vim.b.image_tools_preview_owner)
      tex.setup({ mappings = true, formula_preview = false, image_preview = false })
    end, debug.traceback)
    renderer.prepare, package.loaded.image_tools = prepare, original
    tex.close_formula_preview()
    tex.setup({ mappings = true })
    if not ok then
      error(err)
    end
  end)
  test('image preview options reject invalid limits', function()
    for _, bad in ipairs({
      { delay = -1 },
      { max_lines = 0 },
      { max_bytes = math.huge },
      { enabled = 'yes' },
      { root = 42 },
    }) do
      eq(false, pcall(tex.setup, { image_preview = bad }))
    end
    tex.setup({ mappings = true })
    vim.fn.delete(root, 'rf')
  end)
end
