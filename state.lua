-- Persisted presentation state. The file is also the undo log: it holds the
-- font size from before presentation mode, so it is only removed once every
-- part of restoring has succeeded.

local state = {}

-- A lock older than this is treated as left behind by a crashed run.
state.LOCK_STALE_SECONDS = 120

function state.new(rt)
  local self = {}

  function self.path()
    local base = rt.env("XDG_STATE_HOME")
    if base and base ~= "" then
      return base .. "/rex-presentation-mode.json"
    end
    return (rt.env("HOME") or "") .. "/.local/state/rex-presentation-mode.json"
  end

  function self.lock_path()
    return self.path() .. ".lock"
  end

  local function read_json(path)
    local file = rt.fs.open(path, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    local ok, decoded = pcall(rt.json.decode, text)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
  end

  local function ensure_folder(path)
    local folder = path:match("^(.*)/")
    if not folder then return true end
    return rt.mkdir(folder)
  end

  local function write_atomic(path, encoded, suffix)
    local _, mkdir_err = ensure_folder(path)
    if mkdir_err then return nil, mkdir_err end

    local temporary = path .. (suffix or "") .. ".tmp"
    local file, open_err = rt.fs.open(temporary, "w")
    if not file then return nil, open_err or ("could not write " .. temporary) end
    file:write(encoded)
    file:close()

    local renamed, rename_err = rt.fs.rename(temporary, path)
    if not renamed then
      rt.fs.remove(temporary)
      return nil, rename_err or ("could not replace " .. path)
    end
    return true
  end

  function self.load()
    local decoded = read_json(self.path())
    if not decoded then return { on = false } end
    if decoded.on == nil then decoded.on = false end
    return decoded
  end

  -- Written to a temporary file and renamed, so a crash mid-write cannot leave
  -- a half-written state file behind.
  function self.save(value)
    local encoded, encode_err = rt.json.encode(value)
    if not encoded then return nil, encode_err or "could not encode state" end
    return write_atomic(self.path(), encoded)
  end

  function self.clear()
    rt.fs.remove(self.path())
    return true
  end

  function self.lock()
    local lock_path = self.lock_path()
    local held = read_json(lock_path)
    if held then
      local age = rt.time() - (tonumber(held.at) or 0)
      if age >= 0 and age < state.LOCK_STALE_SECONDS then
        return nil, "presentation mode is already running"
      end
    end

    local token = tostring(rt.time()) .. "-" .. tostring(math.random(1000000))
    local payload = rt.json.encode({ token = token, at = rt.time() }) or "{}"
    local written = write_atomic(lock_path, payload, "." .. token)
    if not written then return nil, "could not create the lock file" end

    local current = read_json(lock_path)
    if not current or current.token ~= token then
      return nil, "presentation mode is already running"
    end

    self.token = token
    return token
  end

  function self.unlock()
    local held = read_json(self.lock_path())
    if held and held.token == self.token then rt.fs.remove(self.lock_path()) end
    self.token = nil
    return true
  end

  function self.force_unlock()
    rt.fs.remove(self.lock_path())
    self.token = nil
    return true
  end

  return self
end

return state
