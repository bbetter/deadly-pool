#!/bin/bash
set -e
MODE="--export-release"
[ "${DEBUG_BUILD}" = "true" ] && MODE="--export-debug"
OUT="${EXPORT_OUT:-export/deadly-pool-server.x86_64}"
mkdir -p export
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless $MODE "Linux Server" "$OUT"
# Only strip release builds — debug builds need symbols for meaningful backtraces
[ "${DEBUG_BUILD}" != "true" ] && strip "$OUT"
echo "Done: $(du -h "$OUT" | cut -f1) -> $OUT"
