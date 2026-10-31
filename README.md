# rex-presentation-mode

`Ctrl+Cmd+P` makes the Rex window readable from across a room, then puts it back.

The terminal font goes to 20pt. The window stays at its current size. ffmpeg records the main display at that size, and stops when you leave presentation mode. The file lands in `~/Movies/Rex/`.

Press the same keys again. The font goes back to what it was, and the recording finishes.

Rex has no action for tab label size. Tab text stays at the app's own size. Pane density is separate too. View, Customize View, Pane Style, Comfortable is the larger one, and this plugin does not change it.

## Install

Clone the repo somewhere permanent, then point Rex at it from `~/.config/rex/init.lua`:

```lua
package.path = os.getenv("HOME") .. "/Documents/Coding/rex-presentation-mode/?.lua;" .. package.path
require("presentation").setup()
```

Then run `rex config reload`.

`setup` takes a key if you want a different one. `require("presentation").setup("ctrl+alt+p")`.

From the command palette the action is Presentation Mode. From the shell:

```sh
rex do presentation_mode
rex do presentation_mode on=false
rex do presentation_mode size=28 record=false
rex do presentation_mode reset=true
```

| Argument | Meaning |
| --- | --- |
| `on` | `true` enters, `false` leaves. Omitted toggles. |
| `size` | Font in points, clamped to 8–72. Defaults to 20. |
| `zoom` | Zoom the focused pane. Off unless `true`. |
| `fullscreen` | Enter full screen. Off unless `true`. |
| `record` | Record the main display. On unless `false`. |
| `output` | Movie path. Defaults to `~/Movies/Rex/presentation-<date>.mov`. |
| `reset` | Force the state back to off and restore everything the last run changed. With nothing recorded, it resets the font to Rex's default. |

## What it changes, and what it does not

- The font only ever grows. If your font is already at 28pt, presentation mode leaves it there rather than shrinking you to 20.
- Leaving replays the exact number of points it added, so the font lands back where it started.
- Rex does not always keep its persisted font size current. When that value agrees with the size the run produced, leaving restores by size instead, which also puts the font back after a change made elsewhere. When it does not agree, the step count is used.
- The first time, the target is measured from the persisted size. If Rex has never written one, it steps up from the default and restores by step count.
- State lives in `$XDG_STATE_HOME/rex-presentation-mode.json`, or `~/.local/state/` when that is unset. It holds the font size from before presentation mode, so it is only removed once every part of the restore has succeeded. A failed restore is reported and retried on the next press.
- A recording that never writes a frame is reported as a failure, and the font goes back. A denied Screen Recording permission shows up straight away instead of as an empty movie.

## Troubleshooting

**The font is stuck large.** Something failed partway through a restore, and the state file still holds the undo information.

```sh
rex do presentation_mode reset=true
```

If nothing was recorded (the state file is gone), `reset=true` calls Rex's own Reset Font Size, so you land back at the app's default. To force a particular size instead, add it:

```sh
rex do presentation_mode reset=true size=14
```

**The recording is empty or missing.**

```sh
brew install ffmpeg
```

macOS also asks for Screen Recording permission for ffmpeg the first time. Grant it in System Settings, Privacy & Security, Screen Recording, then quit and reopen the app that runs ffmpeg.

**`fullscreen=true` fails.** Reading and toggling full screen goes through System Events, which needs Accessibility permission for Rex. Grant it in System Settings, Privacy & Security, Accessibility.

**Font actions do nothing from the shell.** Rex only applies font changes while it is the frontmost app. Bring it forward, or run the command from a Rex terminal.

**"presentation mode is already running".** Another press is still working, or a crashed run left the lock behind. It expires after two minutes; `reset=true` clears it immediately.

## Check

```sh
make unit      # the state machine, against a fake Rex. No app needed.
make verify    # the live app: font, zoom, and a real recording.
```

`make unit` runs under plain `lua` or `luajit`, and needs neither Rex nor ffmpeg. `make verify` raises the live font by four points, zooms the focused pane, records two seconds to a temporary file, then puts everything back. It does not go full screen.

## Layout

| File | Purpose |
| --- | --- |
| `presentation.lua` | The action: enter, leave, reset, and the undo log. |
| `app.lua` | Font size, pane zoom, and full screen. |
| `record.lua` | ffmpeg start, health check, and stop. |
| `state.lua` | The state file and the lock. |
| `deps.lua` | The only module that touches `rex.*` and the filesystem. |
