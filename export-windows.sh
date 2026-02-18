#!/bin/bash
set -e
mkdir -p export
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless --export-release "Windows" "export/deadly-pool.exe"
rm -f export/deadly-pool.console.exe
echo "Done: $(du -h export/deadly-pool.exe | cut -f1) -> export/deadly-pool.exe"
