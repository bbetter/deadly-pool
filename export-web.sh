#!/bin/bash
set -e
mkdir -p export/web
~/Завантажене/Godot_v4.6-stable_linux.x86_64 --headless --export-release "Web" "export/web/deadly-pool.html"
echo "Done: $(du -sh export/web/ | cut -f1) -> export/web/"
echo ""
echo "To test locally with required headers:"
echo "  cd export/web && python3 -c \""
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
