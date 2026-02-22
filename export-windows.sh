#!/bin/bash
set -e
MODE="--export-release"
[ "${DEBUG_BUILD}" = "true" ] && MODE="--export-debug"
OUT="${EXPORT_OUT:-export/deadly-pool.exe}"
mkdir -p export
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless $MODE "Windows" "$OUT"
rm -f "${OUT%.exe}.console.exe"
echo "Done: $(du -h "$OUT" | cut -f1) -> $OUT"
