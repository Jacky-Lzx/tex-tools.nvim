return function(h)
  local test, eq, buffer, at, content, keys = h.test, h.eq, h.buffer, h.at, h.content, h.keys
  local tex = require('tex-tools')
  local source = [=[\section*[简]{中文标题}
body \label{sec:keep}
\subsection{Child}
child
\subsubsection{Grandchild}
% \subsection{comment}
\newcommand{\example}{\section{Definition}}
\begin{verbatim}
\section{literal}
\end{verbatim}
\section{Sibling}
sibling]=]
  test('section demotion shifts the whole subtree and preserves headings and siblings', function()
    buffer(source)
    at('中文标题')
    vim.cmd('let &undolevels = &undolevels')
    eq(true, tex.shift_section(1))
    local expected = source
      :gsub('section%*', 'subsection*')
      :gsub('\\subsection{Child}', '\\subsubsection{Child}')
      :gsub('\\subsubsection{Grandchild}', '\\paragraph{Grandchild}')
    eq(expected, content())
    vim.cmd.undo()
    eq(source, content())
  end)
  test('section promotion from the body and counts affect only the current subtree', function()
    buffer('\\subsection[Short]{A}\nbody\n\\paragraph{B}\nchild\n\\subsection{Next}')
    at('body')
    eq(true, tex.shift_section(-1, 2))
    eq('\\chapter[Short]{A}\nbody\n\\subsection{B}\nchild\n\\subsection{Next}', content())
  end)
  test('section shift refuses a boundary overflow atomically', function()
    for _, source_text in ipairs({ '\\part{Top}\nbody', '\\section{A}\n\\subparagraph{Bottom}\nbody' }) do
      buffer(source_text)
      eq(false, tex.shift_section(source_text:find('Top') and -1 or 1))
      eq(source_text, content())
    end
  end)
  test('section shifts reject invalid counts, missing sections, definitions and read-only targets', function()
    buffer('plain')
    eq(false, tex.shift_section(1))
    buffer('\\newcommand{\\example}{\\section{A}}')
    at('A')
    eq(false, tex.shift_section(1))
    buffer('\\section{A}\nbody')
    at('body')
    eq(false, tex.shift_section(1, 0))
    eq(false, tex.shift_section(0))
    vim.bo.modifiable = false
    eq(false, tex.shift_section(1))
    vim.bo.modifiable = true
  end)
  test('section shifts preserve inline verbatim and all actual descendants', function()
    local source_text = [=[\section{A}
\verb|\subsection{Fake}| literal
\subsection{Real}
body
\section{Sibling}]=]
    buffer(source_text)
    at('Fake')
    eq(true, tex.shift_section(1))
    eq(
      source_text:gsub('\\section{A}', '\\subsection{A}'):gsub('\\subsection{Real}', '\\subsubsection{Real}'),
      content()
    )
  end)
  test('section commands and Plug mappings support dot repeat', function()
    buffer('\\section{A}\nbody\n\\section{B}\nother')
    at('body')
    keys('<Plug>(TexToolsDemoteSection)')
    at('other')
    keys('.')
    eq('\\subsection{A}\nbody\n\\subsection{B}\nother', content())
    vim.cmd.TexToolsPromoteSection()
    eq(true, content():find('\\section{B}', 1, true) ~= nil)
  end)
end
