-- Terminal font, pane zoom, and full screen.
--
-- Rex applies font changes one point at a time through client.font.increase and
-- client.font.decrease, and it writes the new size to the plist a moment later.
-- So the size is read back from the plist when it can be, and a step count is
-- kept as the fallback for when it cannot.

local app = {}

app.BUNDLE = "com.superlogical.rex"
app.FONT_KEY = "Workspace.terminalFontPointSize"
app.MIN_SIZE = 8
app.MAX_SIZE = 72
-- Rex writes FONT_KEY on the first font change, so a fresh install has no value
-- to read. Stepping from the default keeps the first presentation working; the
-- step count still restores the original size afterwards.
app.FALLBACK_SIZE = 14

app.FULLSCREEN_SCRIPT = [[
tell application "System Events"
  tell process "Rex"
    if (count of windows) is 0 then return "none"
    return value of attribute "AXFullScreen" of window 1
  end tell
end tell
]]

function app.steps(current, target)
  return math.floor(target + 0.5) - math.floor(current + 0.5)
end

function app.clamp(size)
  if type(size) ~= "number" then return nil, "size must be a number" end
  if size < app.MIN_SIZE then return app.MIN_SIZE end
  if size > app.MAX_SIZE then return app.MAX_SIZE end
  return math.floor(size + 0.5)
end

function app.new(rt)
  local self = { rt = rt }

  -- A hole in the candidate list would make ipairs stop immediately, so the
  -- env var, the bundled binary, and the PATH name are checked one at a time.
  function self.rex_bin()
    local configured = rt.env("REX")
    if configured and configured ~= "" then return configured end
    local home = rt.env("HOME") or ""
    if home == "" then return "rex" end
    return home .. "/Library/Application Support/" .. app.BUNDLE ..
      "/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  end

  function self.client()
    local listed, err = rt.call("client.list")
    if not listed then return nil, err or "could not list clients" end
    for _, client in ipairs(listed.clients or {}) do
      if (client.info or {}).kind == "app" then return client.client_id end
    end
    return nil, "no Rex app is connected"
  end

  function self.point_size()
    local result, err = rt.run({ "defaults", "read", app.BUNDLE, app.FONT_KEY })
    if not result then return nil, err end
    local size = tonumber(result.stdout)
    if not size then return nil, "font size is missing" end
    return size
  end

  local function font_action(steps)
    if steps > 0 then return "client.font.increase", steps, 1 end
    return "client.font.decrease", -steps, -1
  end

  -- Returns the signed point change that landed. A failure stops there so the
  -- caller can undo with the same number of points in the other direction.
  function self.nudge_font(steps)
    if steps == 0 then return 0 end
    local client, client_err = self.client()
    if not client then return 0, client_err end
    local action, count, direction = font_action(steps)
    local bin = self.rex_bin()
    local applied = 0
    for _ = 1, count do
      local _, err = rt.run({ bin, "-C", client, "do", action })
      if err then return applied, err end
      applied = applied + direction
    end
    return applied
  end

  -- Grows the font to target and reports the size it started from. A size that
  -- cannot be read falls back to `fallback_from`, and the returned `before` is
  -- nil so the caller restores by step count instead of by size.
  function self.resize_to(target, only_grow, fallback_from)
    local current, read_err = self.point_size()
    local known = current ~= nil
    local warning
    if not known then
      current = fallback_from
      if current then
        warning = "could not read the font size (" .. tostring(read_err) ..
          "); assuming " .. tostring(current)
      end
    end
    if not current then return nil, nil, read_err, nil end

    local before = known and current or nil
    local delta = app.steps(current, target)
    if only_grow and delta < 0 then delta = 0 end
    if delta == 0 then return 0, before, nil, warning end

    local applied, nudge_err = self.nudge_font(delta)
    return applied, before, nudge_err, warning
  end

  -- Rex's own Reset Font Size. It is refused when the font already matches the
  -- default, which is the same end state, so that answer only counts as a
  -- failure when Rex cannot act at all.
  function self.reset_font()
    local client, client_err = self.client()
    if not client then return nil, client_err end

    local _, err = rt.run({ self.rex_bin(), "-C", client, "do", "client.font.reset" })
    if not err then return true end
    if not err:find("isn't available", 1, true) then return nil, err end

    local front, front_err = self.is_frontmost()
    if front == nil then return nil, front_err end
    if front then return true end
    return nil, "bring Rex to the front, then run reset again"
  end

  function self.is_frontmost()
    local result, err = rt.run({ "osascript", "-e",
      'tell application "System Events" to get name of first application process whose frontmost is true' })
    if not result then return nil, err end
    return (result.stdout or ""):lower():find("rex", 1, true) ~= nil
  end

  function self.session_view(session_id)
    session_id = session_id or rt.session_id()
    if not session_id then return nil, "no session is selected" end
    local view, err = rt.view({ session_id = session_id })
    if not view then return nil, err or "could not read the session view" end
    return view
  end

  function self.active_window_id(session_id)
    local view = self.session_view(session_id)
    if not view then return nil end
    return view.active_window_id
  end

  local function focused_window(view)
    for _, window in ipairs(view.windows or {}) do
      if window.window_id == view.active_window_id then return window end
    end
  end

  function self.zoom_on(session_id)
    local view, view_err = self.session_view(session_id)
    if not view then return nil, view_err end
    local window = focused_window(view)
    if not window then return nil, "no window is active" end
    if window.zoomed_block_id then return nil end
    if not window.focused_block_id then return nil, "no pane has focus" end
    local zoomed, zoom_err = rt.zoom({ block_id = window.focused_block_id, zoom = true })
    if not zoomed then return nil, zoom_err or "could not zoom the pane" end
    return window.focused_block_id
  end

  function self.zoom_off(block_id)
    if not block_id then return true end
    local unzoomed, err = rt.zoom({ block_id = block_id, zoom = false })
    if not unzoomed then return nil, err or ("could not unzoom " .. block_id) end
    return true
  end

  -- The app toggles full screen on whichever window is in front, so the session
  -- window is selected first. Without that, leaving presentation mode after a
  -- tab switch would toggle the wrong window.
  function self.select_window(session_id, window_id)
    if not session_id then return true end
    local client, client_err = self.client()
    if not client then return nil, client_err end
    local argv = {
      self.rex_bin(), "-C", client, "do", "session.select",
      "session_id=" .. session_id,
    }
    if window_id then argv[#argv + 1] = "window_id=" .. window_id end
    local _, err = rt.run(argv)
    if err then return nil, err end
    return true
  end

  function self.fullscreen()
    local result, err = rt.run({ "osascript", "-e", app.FULLSCREEN_SCRIPT })
    if not result then return nil, err end
    local text = result.stdout:lower()
    if text:find("true", 1, true) then return true end
    if text:find("false", 1, true) then return false end
    return nil, "could not read the full screen state; grant Accessibility permission to Rex"
  end

  local function toggle_fullscreen()
    local client, client_err = self.client()
    if not client then return nil, client_err end
    local _, err = rt.run({ self.rex_bin(), "-C", client, "do", "client.window.fullscreen.toggle" })
    if err then return nil, err end
    rt.sleep(0.4)
    return true
  end

  function self.enter_fullscreen(session_id, window_id)
    if not session_id then return nil, "no session is selected" end
    local selected, select_err = self.select_window(session_id, window_id)
    if not selected then return nil, select_err end
    local already, read_err = self.fullscreen()
    if already == nil then return nil, read_err end
    if already then return false end
    return toggle_fullscreen()
  end

  -- A window that is already windowed needs no change, and an app that has quit
  -- has no window left in full screen, so both count as restored.
  function self.exit_fullscreen(session_id, window_id)
    if not self.client() then return true end
    if session_id then
      local selected, select_err = self.select_window(session_id, window_id)
      if not selected then return nil, select_err end
    end
    local already, read_err = self.fullscreen()
    if already == nil then return nil, read_err end
    if not already then return true end
    return toggle_fullscreen()
  end

  return self
end

return app
