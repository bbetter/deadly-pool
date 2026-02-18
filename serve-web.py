#!/usr/bin/env python3
"""Local test server for Godot web export.
Serves with Cross-Origin headers required for SharedArrayBuffer."""

import http.server
import sys
import os

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "export", "web")

class COOPHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

print(f"Serving {DIRECTORY} on http://localhost:{PORT}")
print(f"Open http://localhost:{PORT}/deadly-pool.html")
http.server.HTTPServer(("", PORT), COOPHandler).serve_forever()
