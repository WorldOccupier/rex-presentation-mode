-- Presentation mode. One key raises the terminal font and records the main
-- display at its current size. The window stays where it is. Press the key
-- again to put the font back and stop the recording.

local M = {}

local ROOT = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
package.path = ROOT .. "?.lua;" .. package.path

local deps = require("deps")
local app = require("app")
local record = require("record")
local state = require("state")

M.DEFAULT_SIZE = 20

local function want(args, name, default)
  if args[name] == nil then return default end
  return args[name]
end

local function with_undo(message, errors)
  if not errors or #errors == 0 then return message end
  return message .. " (restore also failed: " .. table.concat(errors, "; ") .. ")"
end

function M.new(rt)
  local self = {}
  local ui = app.new(rt)
  local recorder = record.new(rt)
  local store = state.new(rt)

  -- The step count is the reliable undo. Rex does not keep the persisted font
  -- size current while the app runs, so the plist is only trusted when it
  -- agrees with the size this run should have produced. When it agrees,
  -- restoring by size also survives a font change made elsewhere.
  local function restore_font(saved)
    local steps = -(saved.font_steps or 0)
    if saved.font_before then
      local current = ui.point_size()
      local expected = saved.font_before + (saved.font_steps or 0)
      if current and math.abs(current - expected) < 0.5 then
        steps = app.steps(current, saved.font_before)
      end
    end
    if steps == 0 then return true end
    local _, nudge_err = ui.nudge_font(steps)
    if nudge_err then return nil, nudge_err end
    return true
  end

  local function undo(applied, zoomed_block, entered, session_id, window_id, recording)
    local errors = {}
    if recording and recording.pid then
      local _, err = recorder.stop(recording.pid)
      if err then errors[#errors + 1] = err end
    end
    if entered then
      local _, err = ui.exit_fullscreen(session_id, window_id)
      if err then errors[#errors + 1] = err end
    end
    if zoomed_block then
      local _, err = ui.zoom_off(zoomed_block)
      if err then errors[#errors + 1] = err end
    end
    if applied and applied ~= 0 then
      local _, err = ui.nudge_font(-applied)
      if err then errors[#errors + 1] = err end
    end
    return errors
  end

  local function with_lock(action)
    local token, lock_err = store.lock()
    if not token then return nil, lock_err end
    local ok, value, err = pcall(action)
    store.unlock()
    if not ok then error(value, 0) end
    return value, err
  end

  -- Restores every part and marks each one done on the saved table, so a retry
  -- after a partial failure does not undo the same thing twice.
  local function restore(saved)
    local errors = {}

    local stopped, stop_err = recorder.stop(saved.record_pid)
    if stop_err then
      errors[#errors + 1] = stop_err
      if not recorder.alive(saved.record_pid) then saved.record_pid = nil end
    else
      saved.record_pid = nil
    end
    if stopped then
      local bytes = recorder.size(saved.recording)
      if not bytes or bytes <= 0 then
        errors[#errors + 1] = "recording is empty: " .. tostring(saved.recording)
      end
    end

    if saved.fullscreen then
      local done, fullscreen_err = ui.exit_fullscreen(saved.session_id, saved.window_id)
      if done then saved.fullscreen = false
      else errors[#errors + 1] = fullscreen_err end
    end
    if saved.zoomed_block then
      local done, zoom_err = ui.zoom_off(saved.zoomed_block)
      if done then saved.zoomed_block = nil
      else errors[#errors + 1] = zoom_err end
    end

    local fonted, font_err = restore_font(saved)
    if fonted then
      saved.font_before = nil
      saved.font_steps = 0
    else
      errors[#errors + 1] = font_err
    end

    return errors
  end

  local function apply_effects(args, target, session_id, window_id)
    local applied, before, font_err, font_warning = ui.resize_to(target, true, app.FALLBACK_SIZE)
    if font_warning then rt.log(font_warning) end
    if font_err then return nil, with_undo(font_err, undo(applied)) end

    local zoomed
    if want(args, "zoom", false) then
      local zoom_err
      zoomed, zoom_err = ui.zoom_on(session_id)
      if zoom_err then return nil, with_undo(zoom_err, undo(applied)) end
    end

    local entered = false
    if want(args, "fullscreen", false) then
      local fullscreen_err
      entered, fullscreen_err = ui.enter_fullscreen(session_id, window_id)
      if fullscreen_err then
        return nil, with_undo(fullscreen_err, undo(applied, zoomed))
      end
    end

    local recording
    if want(args, "record", true) then
      local record_err
      recording, record_err = recorder.start(args.output)
      if record_err then
        return nil, with_undo(record_err,
          undo(applied, zoomed, entered, session_id, window_id))
      end
    end

    return {
      applied = applied,
      before = before,
      zoomed = zoomed,
      entered = entered,
      recording = recording,
    }
  end

  function self.enter_locked(args, session_id)
    local target, size_err = app.clamp(want(args, "size", M.DEFAULT_SIZE))
    if not target then return nil, size_err end

    session_id = session_id or rt.session_id()
    local window_id = ui.active_window_id(session_id)
    local effects, effects_err = apply_effects(args, target, session_id, window_id)
    if not effects then return nil, effects_err end

    local value = {
      on = true,
      font_before = effects.before,
      font_steps = effects.applied,
      zoomed_block = effects.zoomed,
      fullscreen = effects.entered and true or false,
      session_id = session_id,
      window_id = window_id,
      recording = effects.recording and effects.recording.path or nil,
      record_pid = effects.recording and effects.recording.pid or nil,
      started_at = rt.time(),
    }

    local saved, save_err = store.save(value)
    if not saved then
      local errors = undo(
        effects.applied, effects.zoomed, effects.entered,
        session_id, window_id, effects.recording
      )
      return nil, with_undo("could not save presentation state: " .. tostring(save_err), errors)
    end
    return value
  end

  function self.enter(args, session_id)
    return with_lock(function()
      return self.enter_locked(args, session_id)
    end)
  end

  function self.leave_locked()
    local saved = store.load()
    if not saved.on then return { on = false, errors = {} } end

    local errors = restore(saved)
    local active = #errors > 0

    -- State is the undo log, so it stays while any part of the restore failed
    -- and the next press retries only what is left.
    if not active then store.clear() else store.save(saved) end
    local err = active and table.concat(errors, "; ") or nil
    return { on = active, recording = saved.recording, errors = errors }, err
  end

  function self.leave()
    return with_lock(self.leave_locked)
  end

  function self.stale(saved)
    if not saved.on then return false end
    if saved.record_pid and not recorder.alive(saved.record_pid) then return true end
    local started = tonumber(saved.started_at) or 0
    return started > 0 and (rt.time() - started) > 12 * 60 * 60
  end

  function self.reset(args)
    local saved = store.load()
    if saved.record_pid and not recorder.alive(saved.record_pid) then
      saved.record_pid = nil
    end
    local had_font = saved.font_before ~= nil or (saved.font_steps or 0) ~= 0
    local errors = restore(saved)

    if args and args.size ~= nil then
      local target, size_err = app.clamp(args.size)
      if not target then
        errors[#errors + 1] = size_err
      else
        local _, _, resize_err = ui.resize_to(target, false)
        if resize_err then errors[#errors + 1] = resize_err end
      end
    elseif not had_font then
      -- Nothing was recorded to go back to, so ask Rex for its default size.
      local _, font_err = ui.reset_font()
      if font_err then errors[#errors + 1] = font_err end
    end

    store.clear()
    store.force_unlock()
    local err = #errors > 0 and table.concat(errors, "; ") or nil
    return { on = false, errors = errors }, err
  end

  function self.run(ctx, args)
    args = args or {}
    if want(args, "reset", false) then
      local value, err = self.reset(args)
      if err then error(err, 0) end
      return value
    end

    -- An action runs in a stored closure, where rex.session_id is not updated
    -- for each request. The calling context carries the real session.
    local session_id = ctx and ctx.session_id or nil

    local saved = store.load()
    if self.stale(saved) then
      if args.on ~= true then
        local value, err = self.reset({})
        if err then error(err, 0) end
        return value
      end
      rt.log("presentation mode was interrupted; restoring before entering")
      self.reset({})
      saved = { on = false }
    end

    local value, err
    if args.on == true then
      value, err = self.enter(args, session_id)
    elseif args.on == false or saved.on then
      value, err = self.leave()
    else
      value, err = self.enter(args, session_id)
    end

    if not value or err then error(err, 0) end
    return value
  end

  function self.setup(key)
    rex.action({
      name = "presentation_mode",
      title = "Presentation Mode",
      description = "Enlarge the terminal font and record the screen at its current size. Run again to restore.",
      category = "View",
      keywords = "present present presentation zoom font record demo",
      args = {
        ["on"] = "boolean?",
        size = "integer?",
        zoom = "boolean?",
        fullscreen = "boolean?",
        record = "boolean?",
        output = "string?",
        reset = "boolean?",
      },
      run = self.run,
    })
    rex.bind(key or "ctrl+cmd+p", "presentation_mode")
  end

  return self
end

function M.instance()
  if not M._instance then M._instance = M.new(deps.default()) end
  return M._instance
end

function M.setup(key)
  return M.instance().setup(key)
end

function M.run(ctx, args)
  return M.instance().run(ctx, args)
end

return M
