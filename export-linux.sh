#!/bin/bash
set -e
MODE="--export-release"
[ "${DEBUG_BUILD}" = "true" ] && MODE="--export-debug"
OUT="${EXPORT_OUT:-export/deadly-pool.x86_64}"
mkdir -p export
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless $MODE "Linux" "$OUT"
echo "Done: $(du -h "$OUT" | cut -f1) -> $OUT"
