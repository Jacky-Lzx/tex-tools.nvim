local M = {}

function M.show(viewer, client, result, location)
  if client.name ~= 'texquill' then
    return false, 'Pagewing coordinate integration requires texquill'
  end
  if type(result.rootUri) ~= 'string' or type(result.pdfUri) ~= 'string' then
    return false, 'TeXquill did not return a root source and PDF'
  end
  local pdf = vim.uri_to_fname(result.pdfUri)
  local callback, err = require('tex-tools.viewer').callback('pagewing')
  if not callback then
    return false, err
  end
  local ok
  ok, err = require('tex-tools.inverse').register_pdf(pdf, client, result.rootUri, vim.api.nvim_get_current_buf())
  if not ok then
    return false, err
  end
  local argv = { viewer.executable }
  vim.list_extend(argv, viewer.args)
  vim.list_extend(argv, { '--inverse-search-position', callback.shell_command })
  if not viewer.focus then
    argv[#argv + 1] = '--no-focus'
  end
  if location then
    -- Send the server's location verbatim. Pagewing owns page geometry and highlights.
    vim.list_extend(argv, { '--synctex-location', vim.json.encode(location) })
  end
  vim.list_extend(argv, { '--', pdf })
  return require('tex-tools.viewer').start(argv)
end

return M
