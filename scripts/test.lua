#!/usr/bin/env lua
-- Runs under plain lua: the runtime below stands in for rex.* and the
-- filesystem, so the enter and leave flow can be checked without the app.

local root = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
package.path = root .. "../?.lua;" .. package.path

local app = require("app")
local presentation = require("presentation")
local state = require("state")

-- Only flat tables are stored, which is all the state file holds. This stands
-- in for rex.json so the tests need no JSON library.
local function json_encode(value)
  local parts = {}
  for key, item in pairs(value) do
    local rendered
    if type(item) == "string" then
      rendered = string.format("%q", item)
    elseif type(item) == "number" or type(item) == "boolean" then
      rendered = tostring(item)
    end
    if rendered then
      parts[#parts + 1] = "[" .. string.format("%q", key) .. "]=" .. rendered
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local load_chunk = loadstring or load

local function json_decode(text)
  local chunk = load_chunk("return " .. text)
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local OUTPUT = "/tmp/out.mov"

local function new_world()
  return {
    font = 14,
    fullscreen = false,
    app_running = true,
    session = "session-1",
    window = "window-1",
    block = "block-1",
    zoomed = nil,
    disk = {},
    sizes = { [OUTPUT] = 2048 },
    logs = {},
    calls = {},
    now = 1767225600,
    recording_alive = false,
    spawned = nil,
    frontmost = "Rex",
  }
end

local function runtime(world)
  local rt = {
    root = "/repo/",
    json = { encode = json_encode, decode = json_decode },
    env = function(name)
      return ({ HOME = "/home/vatsa", XDG_STATE_HOME = "/state" })[name]
    end,
    date = function() return "2026-10-31-120000" end,
    time = function() return world.now end,
    session_id = function() return world.session end,
    log = function(message) world.logs[#world.logs + 1] = message end,
    sleep = function() end,
  }

  rt.fs = {
    open = function(path, mode)
      if mode == "r" then
        local text = world.disk[path]
        if not text then return nil, "missing " .. path end
        local delivered = false
        return {
          read = function()
            if delivered then return nil end
            delivered = true
            return text
          end,
          close = function() end,
        }
      end
      if world.fail_write then return nil, "disk full" end
      local buffer = {}
      return {
        write = function(_, chunk) buffer[#buffer + 1] = chunk end,
        close = function() world.disk[path] = table.concat(buffer) end,
      }
    end,
    remove = function(path)
      if world.disk[path] == nil then return nil, "missing " .. path end
      world.disk[path] = nil
      return true
    end,
    rename = function(from, to)
      if world.disk[from] == nil then return nil, "missing " .. from end
      world.disk[to] = world.disk[from]
      world.disk[from] = nil
      return true
    end,
  }

  rt.call = function(method)
    if method == "client.list" then
      return { clients = { { client_id = "client-1", info = { kind = "app" } } } }
    end
    return nil, "unknown method " .. tostring(method)
  end

  rt.view = function(params)
    if not params.session_id then return nil, "session_id is required" end
    return {
      active_window_id = world.window,
      windows = { {
        window_id = world.window,
        focused_block_id = world.block,
        zoomed_block_id = world.zoomed,
      } },
    }
  end

  rt.zoom = function(params)
    if params.zoom and world.fail_zoom then return nil, "zoom failed" end
    if not params.zoom and world.fail_zoom_off then return nil, "unzoom failed" end
    world.zoomed = params.zoom and params.block_id or nil
    return true
  end

  rt.exec = function(argv)
    -- Mirrors rex.exec, which rejects anything but a dense list of strings. A
    -- hole or a named key here means the caller built argv wrong.
    local count = 0
    for key, value in pairs(argv) do
      count = count + 1
      if type(key) ~= "number" or type(value) ~= "string" then
        error("argv must be a list of strings, got a " .. type(value) .. " at " .. tostring(key))
      end
    end
    if count == 0 then error("argv is empty") end

    world.calls[#world.calls + 1] = argv
    local program = argv[1]

    if program == "defaults" then
      if world.fail_font_read then return nil, "defaults is not available" end
      return { ok = true, stdout = tostring(world.report_font or world.font), stderr = "" }
    end
    if program == "mkdir" then return { ok = true, stdout = "", stderr = "" } end
    if program == "/repo/scripts/rex-window-id" then
      if world.app_running then return { ok = true, stdout = "12\n", stderr = "" } end
      return { ok = false, code = 1, stdout = "", stderr = "no Rex window" }
    end
    if program == "pgrep" then
      if world.app_running then return { ok = true, stdout = "1\n", stderr = "" } end
      return { ok = false, code = 1, stdout = "", stderr = "" }
    end
    if program == "stat" then
      local bytes = world.sizes[argv[4]]
      if bytes == nil then return { ok = false, code = 1, stdout = "", stderr = "no file" } end
      return { ok = true, stdout = tostring(bytes), stderr = "" }
    end
    if program == "kill" and argv[2] == "-0" then
      if world.recording_alive then return { ok = true, stdout = "", stderr = "" } end
      return { ok = false, code = 1, stdout = "", stderr = "" }
    end
    if program == "kill" and argv[2] == "-INT" then
      world.recording_alive = false
      return { ok = true, stdout = "", stderr = "" }
    end
    if program == "ps" then
      return { ok = true, stdout = "/opt/homebrew/bin/ffmpeg\n", stderr = "" }
    end
    if program == "osascript" then
      if (argv[3] or ""):find("frontmost", 1, true) then
        return { ok = true, stdout = world.frontmost .. "\n", stderr = "" }
      end
      return { ok = true, stdout = tostring(world.fullscreen) .. "\n", stderr = "" }
    end
    if program == "/opt/homebrew/bin/ffmpeg" then
      if argv[2] == "-version" then return { ok = true, stdout = "ffmpeg version 7\n", stderr = "" } end
      return {
        ok = false, code = 1, stdout = "",
        stderr = "[AVFoundation indev] [0] Capture screen 0\n",
      }
    end
    if argv[4] == "do" then
      local action = argv[5]
      if action == "client.font.increase" or action == "client.font.decrease" then
        if world.fail_font then return { ok = false, code = 1, stdout = "", stderr = "font failed" } end
        world.font = world.font + (action == "client.font.increase" and 1 or -1)
        return { ok = true, stdout = "", stderr = "" }
      end
      if action == "session.select" then
        if world.fail_select then return { ok = false, code = 1, stdout = "", stderr = "select failed" } end
        return { ok = true, stdout = "", stderr = "" }
      end
      if action == "client.window.fullscreen.toggle" then
        world.fullscreen = not world.fullscreen
        return { ok = true, stdout = "", stderr = "" }
      end
      if action == "client.font.reset" then
        if world.refuse_font_reset then
          return {
            ok = false, code = 1, stdout = "",
            stderr = [["Reset Font Size" isn't available here right now.]],
          }
        end
        world.font = world.default_font or 14
        return { ok = true, stdout = "", stderr = "" }
      end
      return { ok = true, stdout = "", stderr = "" }
    end
    return { ok = true, stdout = "", stderr = "" }
  end

  rt.run = function(argv)
    local result, err = rt.exec(argv)
    if not result then return nil, err end
    if not result.ok then
      if result.stderr ~= "" then return nil, result.stderr end
      return nil, "exit " .. tostring(result.code)
    end
    return result
  end

  rt.mkdir = function() return true end

  rt.spawn = function(argv)
    world.spawned = argv
    if world.fail_spawn then return nil, "spawn failed" end
    world.recording_alive = true
    return { pid = 4242 }
  end

  return rt
end

local failures = 0

local function check(name, passed, detail)
  if passed then
    io.write("ok   " .. name .. "\n")
  else
    failures = failures + 1
    local suffix = detail ~= nil and (": " .. tostring(detail)) or ""
    io.write("FAIL " .. name .. suffix .. "\n")
  end
end

local function instance(world)
  return presentation.new(runtime(world))
end

local function state_of(world)
  return state.new(runtime(world)).load()
end

local function enter_grows_and_leave_restores()
  local world = new_world()
  local mode = instance(world)

  local value = mode.enter({ record = false })
  check("enter grows to the default size", world.font == 20, world.font)
  check("enter records the size it started from", value and value.font_before == 14)

  mode.leave()
  check("leave restores the original size", world.font == 14, world.font)
end

local function enter_never_shrinks()
  local world = new_world()
  world.font = 28
  local mode = instance(world)

  mode.enter({ record = false })
  check("enter does not shrink a font above the target", world.font == 28, world.font)

  mode.leave()
  check("leave does not shrink it either", world.font == 28, world.font)
end

local function leave_restores_the_saved_size()
  local world = new_world()
  local mode = instance(world)

  mode.enter({ record = false })
  mode.leave()
  check("leave restores when the reported size tracks the font", world.font == 14, world.font)
end

local function stale_reported_size_still_restores()
  local world = new_world()
  world.report_font = 14 -- this Rex build never updates the reported size
  local mode = instance(world)

  mode.enter({ record = false })
  check("a stale reported size still grows the font", world.font == 20, world.font)

  mode.leave()
  check("a stale reported size still restores by step count", world.font == 14, world.font)
end

local function moved_size_falls_back_to_steps()
  local world = new_world()
  local mode = instance(world)

  mode.enter({ record = false })
  world.font = 24
  mode.leave()
  check("a size that moved during the session restores by step count", world.font == 18, world.font)
end

local function failed_zoom_rolls_back()
  local world = new_world()
  world.fail_zoom = true
  local mode = instance(world)

  local value, err = mode.enter({ record = false, zoom = true })
  check("a failed zoom is reported", value == nil and err ~= nil, err)
  check("a failed zoom restores the font", world.font == 14, world.font)
  check("a failed zoom saves no state", state_of(world).on == false)
end

local function failed_save_rolls_back()
  local world = new_world()
  world.fail_write = true
  local mode = instance(world)

  local value, err = mode.enter({ record = false })
  check("a failed save is reported", value == nil and err ~= nil, err)
  check("a failed save restores the font", world.font == 14, world.font)
end

local function failed_restore_keeps_state()
  local world = new_world()
  local mode = instance(world)
  mode.enter({ record = false })

  world.fail_font = true
  local left = mode.leave()
  check("a failed restore is reported", #left.errors == 1, left.errors[1])
  check("a failed restore keeps the state for a retry", state_of(world).on == true)

  world.fail_font = false
  mode.leave()
  check("a retry restores the font", world.font == 14, world.font)
  check("a successful retry clears the state", state_of(world).on == false)
end

local function retry_does_not_repeat_the_font()
  local world = new_world()
  local mode = instance(world)
  mode.enter({ record = false, zoom = true })

  world.fail_zoom_off = true
  local left = mode.leave()
  check("the failed unzoom is reported", #left.errors == 1, left.errors[1])
  check("the font is still restored", world.font == 14, world.font)

  world.fail_zoom_off = false
  mode.leave()
  check("the retry does not shrink the font again", world.font == 14, world.font)
  check("the retry clears the state", state_of(world).on == false)
end

local function empty_recording_fails_cleanly()
  local world = new_world()
  world.sizes[OUTPUT] = 0
  local mode = instance(world)

  local value, err = mode.enter({ output = OUTPUT })
  check("a recording that writes nothing is reported", value == nil and err ~= nil, err)
  check("a failed recording restores the font", world.font == 14, world.font)
  check("a failed recording leaves no ffmpeg behind", world.recording_alive == false)
end

local function recording_starts_and_stops()
  local world = new_world()
  local mode = instance(world)

  local value = mode.enter({ output = OUTPUT })
  check("recording reports a pid", value and value.record_pid == 4242)
  local left = mode.leave()
  check("leave reports no errors", #left.errors == 0, left.errors[1])
  check("leave stops the recording", world.recording_alive == false)
end

local function size_is_clamped()
  local world = new_world()
  local mode = instance(world)

  mode.enter({ size = 200, record = false })
  check("a huge size is clamped", world.font == app.MAX_SIZE, world.font)
end

local function lock_refuses_a_second_enter()
  local world = new_world()
  state.new(runtime(world)).lock()
  local mode = instance(world)

  local value, err = mode.enter({ record = false })
  check("a second enter is refused while locked", value == nil and err ~= nil, err)
end

local function stale_state_does_not_block()
  local world = new_world()
  world.font = 20
  state.new(runtime(world)).save({
    on = true, record_pid = 999, font_before = 14, font_steps = 6, started_at = world.now,
  })
  world.recording_alive = false
  local mode = instance(world)

  local value = mode.run(nil, { size = 24, record = false })
  check("stale state lets enter proceed", value and value.on == true)
  check("stale state is restored before entering again", value and value.font_before == 14,
    value and value.font_before)
  check("stale state is replaced", state_of(world).on == true)
end

local function reset_moves_the_font()
  local world = new_world()
  local mode = instance(world)
  mode.enter({ record = false })

  mode.reset({ size = 16 })
  check("reset moves the font to the requested size", world.font == 16, world.font)
  check("reset clears the state", state_of(world).on == false)
end

local function reset_without_a_record_uses_the_app_reset()
  local world = new_world()
  world.font = 26
  world.default_font = 10
  local mode = instance(world)

  local value = mode.reset({})
  check("reset without a record calls the app reset", world.font == 10, world.font)
  check("reset without a record reports no errors", #value.errors == 0, value.errors[1])
end

local function reset_with_a_record_skips_the_app_reset()
  local world = new_world()
  world.default_font = 10
  local mode = instance(world)
  mode.enter({ record = false })

  mode.reset({})
  check("reset with a record returns to the recorded size", world.font == 14, world.font)
end

local function reset_refused_in_front_is_done()
  local world = new_world()
  world.font = 26
  world.refuse_font_reset = true
  world.frontmost = "Rex"
  local mode = instance(world)

  local value = mode.reset({})
  check("a refused reset counts as done when Rex is in front", #value.errors == 0, value.errors[1])
end

local function reset_refused_behind_reports_it()
  local world = new_world()
  world.refuse_font_reset = true
  world.frontmost = "Google Chrome"
  local mode = instance(world)

  local value = mode.reset({})
  check("a refused reset behind another app is reported", #value.errors == 1, value.errors[1])
end

local function missing_font_size_falls_back()
  local world = new_world()
  world.fail_font_read = true
  local mode = instance(world)

  mode.enter({ record = false })
  check("a missing font size still grows from the fallback", world.font == 20, world.font)
  mode.leave()
  check("a missing font size restores by step count", world.font == 14, world.font)
end

local function context_session_wins()
  local world = new_world()
  world.session = nil
  local mode = instance(world)

  local value = mode.run({ session_id = "from-context" }, { record = false })
  check("the calling context supplies the session", value and value.on == true)
end

local function state_honours_xdg()
  local world = new_world()
  local store = state.new(runtime(world))
  check("state honours XDG_STATE_HOME",
    store.path() == "/state/rex-presentation-mode.json", store.path())
end

local tests = {
  enter_grows_and_leave_restores,
  enter_never_shrinks,
  leave_restores_the_saved_size,
  stale_reported_size_still_restores,
  moved_size_falls_back_to_steps,
  failed_zoom_rolls_back,
  failed_save_rolls_back,
  failed_restore_keeps_state,
  retry_does_not_repeat_the_font,
  empty_recording_fails_cleanly,
  recording_starts_and_stops,
  size_is_clamped,
  lock_refuses_a_second_enter,
  stale_state_does_not_block,
  reset_moves_the_font,
  reset_without_a_record_uses_the_app_reset,
  reset_with_a_record_skips_the_app_reset,
  reset_refused_in_front_is_done,
  reset_refused_behind_reports_it,
  missing_font_size_falls_back,
  context_session_wins,
  state_honours_xdg,
}

for _, test in ipairs(tests) do
  test()
end

if failures > 0 then
  io.write(failures .. " failed\n")
  os.exit(1)
end
io.write("all passed\n")
