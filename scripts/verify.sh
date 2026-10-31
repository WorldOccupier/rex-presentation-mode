#!/bin/sh
# Turns presentation mode on and off against the live Rex app and checks what it
# changed. Leaves the app as it found it, including after a failure.
set -eu

REX="${REX:-$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex}"
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
FONT_KEY="Workspace.terminalFontPointSize"

"$REX" do "$ROOT/scripts/test_steps.lua" >/dev/null
echo "steps"
"$REX" do "$ROOT/scripts/test.lua" >/dev/null
echo "state machine"

if ! "$REX" do presentation_mode on=false >/dev/null 2>&1; then
  echo "presentation_mode is not loaded; run 'rex config reload'" >&2
  exit 1
fi
echo "cleared"

# The app only resizes the session in front. Its window title ends with that label.
cell() {
  "$REX" api call session.list | python3 -c '
import json, subprocess, sys
rex = sys.argv[1]
title = subprocess.check_output([
    "osascript", "-e",
    "tell application \"System Events\" to tell process \"Rex\" to get name of window 1",
], text=True).strip()
sessions = json.load(sys.stdin)["sessions"]
match = None
for session in sessions:
    label = session.get("label") or ""
    if label and title.endswith(label):
        match = session
if match is None:
    raise SystemExit("front window %r matches no session" % title)
sid = match["session_id"]
view = json.loads(subprocess.check_output([
    rex, "api", "call", "session.view", json.dumps({"session_id": sid})
]))
for window in view.get("windows") or []:
    if window.get("window_id") != view.get("active_window_id"):
        continue
    bid = window.get("focused_block_id")
    if not bid:
        continue
    size = json.loads(subprocess.check_output([
        rex, "api", "call", "block.method",
        json.dumps({"session_id": sid, "block_id": bid, "method": "size"}),
    ]))
    zoomed = window.get("zoomed_block_id") or "-"
    print("%s %s %s %s" % (size["cell_height_px"], size["columns"], zoomed, sid))
    raise SystemExit
raise SystemExit("front session has no focused block")
' "$REX"
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

before=$(cell)
before_h=$(echo "$before" | awk '{print $1}')
before_cols=$(echo "$before" | awk '{print $2}')
before_zoom=$(echo "$before" | awk '{print $3}')
sid=$(echo "$before" | awk '{print $4}')
if ! is_number "$before_h" || ! is_number "$before_cols"; then
  echo "could not read the cell size: $before" >&2
  exit 1
fi
echo "before height=$before_h columns=$before_cols session=$sid"

off() {
  "$REX" do -s "$sid" presentation_mode on=false >/dev/null 2>&1 || true
}
trap off EXIT

# The plugin only grows the font, so the target has to sit above the current
# size rather than being a fixed number.
point=$(defaults read com.superlogical.rex "$FONT_KEY" 2>/dev/null || echo 14)
case "$point" in ''|*[!0-9]*) point=14 ;; esac
size=$((point + 4))

"$REX" do -s "$sid" presentation_mode size="$size" zoom=true fullscreen=false record=false
after=$(cell)
after_h=$(echo "$after" | awk '{print $1}')
after_zoom=$(echo "$after" | awk '{print $3}')
echo "during height=$after_h zoomed=$after_zoom"

if ! is_number "$after_h" || [ "$after_h" -le "$before_h" ]; then
  echo "font did not grow ($before_h -> $after_h)" >&2
  exit 1
fi
if [ "$before_zoom" = "-" ] && [ "$after_zoom" = "-" ]; then
  echo "focused pane did not zoom" >&2
  exit 1
fi

off
trap - EXIT
restored=$(cell)
restored_h=$(echo "$restored" | awk '{print $1}')
restored_cols=$(echo "$restored" | awk '{print $2}')
restored_zoom=$(echo "$restored" | awk '{print $3}')
echo "after height=$restored_h columns=$restored_cols"

if [ "$restored_h" -ne "$before_h" ] || [ "$restored_cols" -ne "$before_cols" ]; then
  echo "font was not restored ($before_h/$before_cols -> $restored_h/$restored_cols)" >&2
  exit 1
fi
if [ "$restored_zoom" != "$before_zoom" ]; then
  echo "zoom was not restored" >&2
  exit 1
fi
echo "font and zoom restored"

# Recording is the part that fails silently when Screen Recording permission is
# missing, so the file is checked for content rather than just for existing.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; off' EXIT
movie="$tmp/smoke.mov"
"$REX" do -s "$sid" presentation_mode size="$size" zoom=false fullscreen=false record=true output="$movie"
sleep 2
off
trap 'rm -rf "$tmp"' EXIT

if [ ! -s "$movie" ]; then
  echo "recording is empty: $movie" >&2
  exit 1
fi
echo "recording $(wc -c < "$movie" | tr -d ' ') bytes"
rm -rf "$tmp"
trap - EXIT
echo "verified"
