local M = {}

local script = [[on run argv
  set thePath to POSIX path of ((POSIX file (item 1 of argv)) as alias)
  set pageNumber to (item 2 of argv) as integer
  set syncX to (item 3 of argv) as real
  set syncY to (item 4 of argv) as real
  set shouldFocus to (item 7 of argv) is "true"
  tell application id "net.sourceforge.skim-app.skim"
    repeat 50 times
      set theDocs to documents whose path is thePath
      if (count of theDocs) > 0 then
        set theDoc to item 1 of theDocs
        if (count of pages of theDoc) >= pageNumber then
          set thePage to page pageNumber of theDoc
          set pageBounds to media bounds of thePage
          set pdfX to (item 1 of pageBounds) + syncX
          set pdfY to (item 2 of pageBounds) - syncY
          repeat 10 times
            go theDoc to thePage at {pdfX, pdfY}
            delay 0.1
            go theDoc to thePage at {pdfX, pdfY}
            delay 0.1
            if (index of current page of theDoc) is pageNumber then
              if (item 5 of argv) is not "" then
                -- Draw Skim's native, temporary SyncTeX indicator.
                set has reading bar of theDoc to false
                go theDoc to TeX line (item 6 of argv as integer) from POSIX file (item 5 of argv)
              end if
              if shouldFocus then activate
              return pageNumber
            end if
          end repeat
          error "Skim did not finish positioning the PDF"
        end if
      end if
      delay 0.1
    end repeat
  end tell
  error "Skim did not finish opening the PDF"
end run]]

local function run(argv, callback)
  if vim.fn.executable(argv[1]) ~= 1 then
    return false, 'PDF viewer executable is unavailable: ' .. argv[1]
  end
  local ok, process = pcall(
    vim.system,
    argv,
    { text = true, timeout = 10000 },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or '')
        vim.notify(
          message ~= '' and message or ('PDF viewer exited with status ' .. result.code),
          vim.log.levels.WARN,
          { title = 'tex-tools' }
        )
      elseif callback then
        callback()
      end
    end)
  )
  return ok, ok and process or tostring(process)
end

function M.show(viewer, pdf, location, position)
  -- LaunchServices avoids blocking on Skim's first AppleScript open reply.
  -- The script then waits for the document and the requested page to be ready.
  local argv = { viewer.executable }
  vim.list_extend(argv, viewer.args)
  if not viewer.focus then
    argv[#argv + 1] = '-g'
  end
  vim.list_extend(argv, { '-a', 'Skim', pdf })
  local source = position and vim.uri_to_fname(position.uri) or ''
  local line = position and position.position.line + 1 or 1
  return run(argv, function()
    local ok, err = run({
      'osascript',
      '-e',
      script,
      pdf,
      tostring(location.page),
      tostring(location.x),
      tostring(location.y),
      source,
      tostring(line),
      tostring(viewer.focus),
    })
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'tex-tools' })
    end
  end)
end

return M
