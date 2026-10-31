-- Records the main display at its current size.
--
-- ffmpeg finishes the movie when it gets SIGINT, so leaving presentation mode
-- can stop the recording. Starting one is only reported as a success once the
-- process is still alive and the file is growing, because a denied Screen
-- Recording permission kills ffmpeg immediately.

local record = {}

record.FOLDER = "/Movies/Rex"
record.START_TIMEOUT = 5
record.STOP_TIMEOUT = 5
record.POLL_SECONDS = 0.2

local function quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function dir_of(path)
  return path:match("^(.*)/") or "."
end

local function last_line(text)
  local line
  for candidate in text:gmatch("[^\n]+") do line = candidate end
  return line or text
end

function record.new(rt)
  local self = {}

  function self.directory()
    return (rt.env("HOME") or "") .. record.FOLDER
  end

  function self.output_path()
    return self.directory() .. "/presentation-" .. rt.date("%Y-%m-%d-%H%M%S") .. ".mov"
  end

  function self.alive(pid)
    if not pid then return false end
    local result = rt.exec({ "kill", "-0", tostring(pid) })
    return result ~= nil and result.ok
  end

  function self.size(path)
    if not path then return nil end
    local result = rt.exec({ "stat", "-f", "%z", path })
    if not result or not result.ok then return nil end
    return tonumber(result.stdout)
  end

  function self.is_ffmpeg(pid)
    local result = rt.exec({ "ps", "-p", tostring(pid), "-o", "comm=" })
    if not result or not result.ok then return false end
    return (result.stdout or ""):find("ffmpeg", 1, true) ~= nil
  end

  -- The window ID probe answers the same question as pgrep but also compiles
  -- and runs Swift, so pgrep is tried last as the cheap path.
  function self.app_open()
    local probe = rt.root .. "scripts/rex-window-id"
    local result = rt.exec({ probe })
    if result and result.ok then return true end
    local fallback = rt.exec({ "pgrep", "-x", "Rex" })
    if fallback and fallback.ok then return true end
    return nil, "no Rex app is running"
  end

  function self.ffmpeg()
    if self._ffmpeg then return self._ffmpeg end
    local candidates = { "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "ffmpeg" }
    for _, path in ipairs(candidates) do
      local result = rt.exec({ path, "-version" })
      if result and result.ok then
        self._ffmpeg = path
        return path
      end
    end
    return nil, "ffmpeg is not installed (brew install ffmpeg)"
  end

  -- ffmpeg prints the device list on stderr and exits non-zero, which is how it
  -- lists devices.
  function self.screen_index(ff)
    local listed = rt.exec({
      ff, "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "",
    })
    local text = ""
    if listed then text = (listed.stderr or "") .. (listed.stdout or "") end
    local index = text:match("%[(%d+)%] Capture screen 0")
    if not index then return nil, "ffmpeg found no screen capture device" end
    return index
  end

  function self.read_log(path)
    local file = rt.fs.open(path, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
  end

  function self.failure(log)
    local text = self.read_log(log)
    if text and text ~= "" then return "recording failed: " .. last_line(text) end
    return "recording failed; check Screen Recording permission for ffmpeg"
  end

  -- Returns as soon as ffmpeg is alive with a non-empty file, so a permission
  -- failure surfaces here instead of as an empty movie at the end.
  function self.wait_for_capture(pid, path, log)
    local waited = 0
    while waited < record.START_TIMEOUT do
      if not self.alive(pid) then return nil, self.failure(log) end
      local bytes = self.size(path)
      if bytes and bytes > 0 then return true end
      rt.sleep(record.POLL_SECONDS)
      waited = waited + record.POLL_SECONDS
    end
    return nil, self.failure(log)
  end

  -- A capture that never produced a frame is stopped here, so a failed start
  -- does not leave ffmpeg running in the background.
  function self.abort(pid)
    if not pid or not self.alive(pid) then return true end
    if not self.is_ffmpeg(pid) then return true end
    rt.exec({ "kill", "-INT", tostring(pid) })
    return true
  end

  function self.start(path)
    path = path or self.output_path()
    local open, open_err = self.app_open()
    if not open then return nil, open_err end
    local _, mkdir_err = rt.mkdir(dir_of(path))
    if mkdir_err then return nil, mkdir_err end

    local ff, ff_err = self.ffmpeg()
    if not ff then return nil, ff_err end
    local index, index_err = self.screen_index(ff)
    if not index then return nil, index_err end

    local log = path .. ".log"
    local command = "exec " .. quote(ff) ..
      " -y -hide_banner -loglevel error" ..
      " -f avfoundation -framerate 15 -pixel_format nv12" ..
      " -i " .. quote(index .. ":none") ..
      " " .. quote(path) ..
      " 2>" .. quote(log)
    local handle, spawn_err = rt.spawn({ "/bin/sh", "-c", command }, { detach = true })
    if not handle then return nil, spawn_err or "could not start ffmpeg" end

    local captured, capture_err = self.wait_for_capture(handle.pid, path, log)
    if not captured then
      self.abort(handle.pid)
      return nil, capture_err
    end
    return { path = path, pid = handle.pid, log = log }
  end

  -- Verifies the PID is still ffmpeg before signalling it: after a reboot the
  -- stored PID may belong to something else. Waits for the process to exit so
  -- the movie's index is written before the file is reported as finished.
  function self.stop(pid)
    if not pid then return nil end
    if not self.alive(pid) then
      return nil, "ffmpeg stopped before presentation mode ended"
    end
    if not self.is_ffmpeg(pid) then
      return nil, "refusing to signal PID " .. tostring(pid) .. ", which is not ffmpeg"
    end
    rt.exec({ "kill", "-INT", tostring(pid) })

    local waited = 0
    while self.alive(pid) and waited < record.STOP_TIMEOUT do
      rt.sleep(record.POLL_SECONDS)
      waited = waited + record.POLL_SECONDS
    end
    if self.alive(pid) then
      return nil, "ffmpeg did not stop within " .. record.STOP_TIMEOUT .. "s"
    end
    return true
  end
  return self
end

return record
