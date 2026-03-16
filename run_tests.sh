#!/bin/bash
# Run the headless unit test suite.
# Usage: ./run_tests.sh

GODOT_SOURCE="${GODOT:-$HOME/Завантажене/Godot_v4.6-stable_linux.x86_64}"
GODOT_SAFE_BIN="${GODOT_SAFE_BIN:-/tmp/Godot_v4.6-stable_linux.x86_64}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$GODOT_SOURCE" ]; then
    echo "ERROR: Godot not found at $GODOT_SOURCE"
    echo "Set GODOT=/path/to/godot binary and retry."
    exit 1
fi

if [ ! -x "$GODOT_SAFE_BIN" ] || [ "$GODOT_SOURCE" -nt "$GODOT_SAFE_BIN" ]; then
    cp "$GODOT_SOURCE" "$GODOT_SAFE_BIN"
    chmod +x "$GODOT_SAFE_BIN"
fi

export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/godot-data}"
mkdir -p "$XDG_DATA_HOME"

"$GODOT_SAFE_BIN" --headless --path "$PROJECT_DIR" res://test/test_suite.tscn
