#!/bin/bash
set -e
mkdir -p export
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless --export-release "Linux Server" "export/deadly-pool-server.x86_64"
strip export/deadly-pool-server.x86_64
echo "Done: $(du -h export/deadly-pool-server.x86_64 | cut -f1) -> export/deadly-pool-server.x86_64"
