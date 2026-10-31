#!/bin/sh
# Builds the window ID probe that record.app_open prefers. The plugin falls back
# to pgrep when the binary is missing, so this step is optional.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)

swiftc -O "$ROOT/rex-window-id.swift" -o "$ROOT/rex-window-id"
echo "built $ROOT/rex-window-id"
