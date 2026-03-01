#!/bin/bash
set -e
DIR="${EXPORT_DIR:-export/web}"
MODE="--export-release"
[ "${DEBUG_BUILD}" = "true" ] && MODE="--export-debug"
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
mkdir -p "$DIR"
"$GODOT_SAFE_BIN" --headless $MODE "Web" "$DIR/deadly-pool.html"
echo "Done: $(du -sh "$DIR/" | cut -f1) -> $DIR/"
echo ""
echo "To test locally with required headers:"
echo "  cd $DIR && python3 -c \""
echo "import http.server, functools"
echo "Handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory='.')"
echo "class COOPHandler(Handler):"
echo "    def end_headers(self):"
echo "        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')"
echo "        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')"
echo "        super().end_headers()"
echo "http.server.HTTPServer(('', 8000), COOPHandler).serve_forever()\""
echo ""
echo "Then open http://localhost:8000/deadly-pool.html"
