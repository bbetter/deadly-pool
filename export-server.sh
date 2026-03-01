#!/bin/bash
set -e
MODE="--export-release"
[ "${DEBUG_BUILD}" = "true" ] && MODE="--export-debug"
OUT="${EXPORT_OUT:-export/deadly-pool-server.x86_64}"
GODOT_SOURCE="${GODOT:-$HOME/Завантажене/Godot_v4.6-stable_linux.x86_64}"
GODOT_SAFE_BIN="${GODOT_SAFE_BIN:-/tmp/Godot_v4.6-stable_linux.x86_64}"
if [ ! -f "$GODOT_SOURCE" ]; then
  echo "ERROR: Godot not found at $GODOT_SOURCE"
  exit 1
fi
if [ ! -x "$GODOT_SAFE_BIN" ] || [ "$GODOT_SOURCE" -nt "$GODOT_SAFE_BIN" ]; then
  cp "$GODOT_SOURCE" "$GODOT_SAFE_BIN"
  chmod +x "$GODOT_SAFE_BIN"
fi
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/godot-data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/godot-config}"
mkdir -p "$XDG_DATA_HOME"
mkdir -p "$XDG_CONFIG_HOME"
if [ -d "$HOME/.local/share/godot/export_templates" ]; then
  mkdir -p "$XDG_DATA_HOME/godot/export_templates"
  if [ ! -f "$XDG_DATA_HOME/godot/export_templates/4.6.stable/linux_release.x86_64" ]; then
    cp -a "$HOME/.local/share/godot/export_templates/." "$XDG_DATA_HOME/godot/export_templates/"
  fi
fi
mkdir -p export
"$GODOT_SAFE_BIN" --headless $MODE "Linux Server" "$OUT"
# Only strip release builds — debug builds need symbols for meaningful backtraces
[ "${DEBUG_BUILD}" != "true" ] && strip "$OUT"
echo "Done: $(du -h "$OUT" | cut -f1) -> $OUT"
