-- A standalone setup can run before any TeX buffer exists.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local tex = require('tex-tools')
assert(not package.loaded['tex-tools.formula'])
assert(not tex.formula_info().enabled)
tex.setup({ conceal = false, mappings = false, formula_preview = { enabled = true } })
assert(not package.loaded['tex-tools.formula'], 'setup loaded the preview controller without a TeX buffer')
assert(tex.formula_info().enabled and tex.formula_info().stage == 'idle')
tex.set_auto_preview(false)
tex.set_auto_preview(false)
assert(not tex.formula_info().enabled and not tex.formula_info().images_enabled)
assert(not package.loaded['tex-tools.formula'], 'setter activated a cold controller')
tex.set_auto_preview(true)
assert(tex.formula_info().enabled)
assert(tex.close_formula_preview())
assert(not package.loaded['tex-tools.formula'], 'inspection/close initialized previews')
vim.bo.filetype = 'lua'
assert(not package.loaded['tex-tools.formula'])
tex.setup({ conceal = false, mappings = false, formula_preview = false, image_preview = false })
vim.bo.filetype = 'tex'
assert(not package.loaded['tex-tools.formula'])
local preview = require('tex-tools.formula')
local setup, calls = preview.setup, 0
preview.setup = function(...)
  calls = calls + 1
  return setup(...)
end
vim.cmd('TexToolsFormulaPreview')
assert(calls == 1)
tex.preview()
assert(calls == 1, 'switching from a native command to the public API reinitialized previews')
preview.setup = setup
tex.setup({ conceal = false, mappings = false, formula_preview = { enabled = true } })
assert(package.loaded['tex-tools.formula'] and vim.b.tex_tools_generation)
assert(not package.loaded['tex-tools.formula.render'], 'attachment loaded the compiler')
local controller = package.loaded['tex-tools.formula']
vim.cmd.enew()
vim.bo.filetype = 'tex'
assert(package.loaded['tex-tools.formula'] == controller and vim.b.tex_tools_generation)
tex.setup({
  conceal = false,
  mappings = false,
  formula_preview = { enabled = false },
  image_preview = { enabled = false },
})
assert(not tex.formula_info().enabled and not tex.formula_info().images_enabled)
print('lazy previews: cold setup, read-only inspection, first/repeated buffers and reconfiguration passed')
