return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  for _, fixture in ipairs({
    { '\\section[Short]{Title}\nbody', 'Title', '\\section*[Short]{Title}\nbody' },
    { '\\foo*{中文}', '中文', '\\foo{中文}' },
  }) do
    test('extra editing command star ' .. fixture[2], function()
      buffer(fixture[1])
      at(fixture[2])
      eq(true, tex.toggle_command_star())
      eq(fixture[3], content())
    end)
  end
  for i, fixture in ipairs({
    { '$a/b$', '/', '$\\frac{a}{b}$' },
    { '${a+b}/{c+d}$', '/', '$\\frac{a+b}{c+d}$' },
    { '$x^2/\\sqrt{y}$', '/', '$\\frac{x^2}{\\sqrt{y}}$' },
    { '$\\frac{a}{b}$', 'frac', '$a/b$' },
    { '$\\dfrac{a+b}{c+d}$', 'dfrac', '${a+b}/{c+d}$' },
  }) do
    test('extra editing fractions ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(true, tex.toggle_fraction())
      eq(fixture[3], content())
    end)
  end
  for i, fixture in ipairs({
    { '$a/b/c$', '/' },
    { '$\\frac{}{b}$', 'frac' },
    { '$\\text{a/b}$', '/' },
    { '% $a/b$', '/' },
    { '$\\frac{a}% keep\n{b}$', 'frac' },
  }) do
    test('extra editing fraction refusal ' .. i, function()
      buffer(fixture[1])
      at(fixture[2])
      eq(false, tex.toggle_fraction())
      eq(fixture[1], content())
    end)
  end
  for i, fixture in ipairs({
    { '$a+b$', 'display', '\\[a+b\\]' },
    { '\\[a+b\\]', 'inline', '\\(a+b\\)' },
    { '$a+b$', 'equation*', '\\begin{equation*}\na+b\n\\end{equation*}' },
    { '\\begin{equation}\na+b\n\\end{equation}', 'display', '\\[\na+b\n\\]' },
  }) do
    test('extra editing math conversion ' .. i, function()
      buffer(fixture[1])
      at('a+b')
      eq(true, tex.convert_math(fixture[2]))
      eq(fixture[3], content())
    end)
  end
  for i, fixture in ipairs({
    { '\\begin{align}\na&=b\\\\ c&=d\n\\end{align}', 'inline' },
    { '\\[a % keep\n+b\\]', 'inline' },
    { '$a+b', 'display' },
    { '\\begin{equation}\na\\label{x}\n\\end{equation}', 'inline' },
  }) do
    test('extra editing math conversion refusal ' .. i, function()
      buffer(fixture[1])
      at('a')
      eq(false, tex.convert_math(fixture[2]))
      eq(fixture[1], content())
    end)
  end
  test('extra editing section hierarchy and operator', function()
    buffer('\\section{One}\nbody\n\\subsection{Child}\nchild\n\\section{Two}\nother')
    at('child')
    keys('diP')
    eq('\\section{One}\nbody\n\\subsection{Child}\n\n\\section{Two}\nother', content())
    buffer('\\section{One}\nbody\n\\subsection{Child}\nchild\n\\section{Two}\nother')
    at('child')
    keys('d2aP')
    eq('\\section{Two}\nother', content())
  end)
  for i, fixture in ipairs({
    { '{abc', '}' },
    { '(abc', ')' },
    { '[abc', ']' },
    { '$\\left(abc', '\\right)' },
    { '$abc', '$' },
    { '\\(abc', '\\)' },
    { '\\begin{align}\nabc', '\\end{align}' },
  }) do
    test('extra editing insert closing marker ' .. i, function()
      buffer(fixture[1])
      keys('GA]]<Esc>')
      eq(fixture[1] .. fixture[2], content())
    end)
  end
  test('extra editing closing marker fallback and existing closer', function()
    buffer('{abc}')
    at('abc')
    keys('i]]<Esc>')
    eq('{]]abc}', content())
    buffer('% {abc')
    keys('A]]<Esc>')
    eq('% {abc]]', content())
  end)
  test('extra editing fraction undo and semantic dot', function()
    buffer('$a/b$ $c/d$')
    at('/')
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.toggle_fraction())
    keys('u')
    eq('$a/b$ $c/d$', content())
    keys('<C-r>')
    at('c/d')
    keys('.')
    eq('$\\frac{a}{b}$ $\\frac{c}{d}$', content())
  end)
end
