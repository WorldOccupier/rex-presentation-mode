-- The only module that touches rex.*, os.*, and io.*. Everything else takes a
-- runtime table, so the enter and leave flow can run against a fake in tests.

local deps = {}

local function describe(result)
  if result.stderr and result.stderr ~= "" then return result.stderr end
  if result.stdout and result.stdout ~= "" then return result.stdout end
  return "exit " .. tostring(result.code)
end

function deps.fs()
  return {
    open = function(path, mode) return io.open(path, mode) end,
    remove = function(path) return os.remove(path) end,
    rename = function(from, to) return os.rename(from, to) end,
  }
end

function deps.default()
  local rt = {
    fs = deps.fs(),
    json = rex.json,
    env = function(name) return os.getenv(name) end,
    date = function(format) return os.date(format) end,
    time = function() return os.time() end,
    session_id = function() return rex.session_id end,
    log = function(message) rex.log(message) end,
    -- rex.sleep exists in scripts but not in an action loaded from init.lua,
    -- so the fallback waits through the sleep program.
    sleep = function(seconds)
      if type(rex.sleep) == "function" then return rex.sleep(seconds) end
      rex.exec({ "sleep", tostring(seconds) })
    end,
    call = function(method) return rex.call(method) end,
    view = function(params) return rex.session.view(params) end,
    zoom = function(params) return rex.session.zoom_block(params) end,
    exec = function(argv) return rex.exec(argv) end,
    spawn = function(argv, options) return rex.exec.start(argv, options) end,
  }

  -- Runs a program and turns a non-zero exit into a readable message.
  function rt.run(argv)
    local result, err = rex.exec(argv)
    if not result then return nil, err or ("could not run " .. tostring(argv[1])) end
    if not result.ok then return nil, describe(result) end
    return result
  end

  function rt.mkdir(path)
    local result, err = rex.exec({ "mkdir", "-p", path })
    if not result then return nil, err or ("could not create " .. path) end
    if not result.ok then return nil, describe(result) end
    return true
  end

  return rt
end

return deps
