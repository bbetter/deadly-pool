#!/bin/bash
set -e

# Usage: ./release.sh [targets...] [--deploy]
#
# Targets (default: server web):
#   server  - Export headless server, build Docker image
#   web     - Export web client
#   linux   - Export Linux native client
#   win     - Export Windows native client
#   all     - All of the above
#
# Examples:
#   ./release.sh                    # build server + web
#   ./release.sh --deploy           # build server + web, deploy to minipc
#   ./release.sh all --deploy       # build everything, deploy
#   ./release.sh win linux          # build native clients only
#   ./release.sh server --deploy    # rebuild and deploy server only

REMOTE_HOST="andri@192.168.0.108"
REMOTE_BUILDS_DIR="~/caddy/sites/deadly-pool"
REMOTE_WEB_DIR="~/caddy/sites/deadly-pool/web"
IMAGE_NAME="deadly-pool"
CONTAINER_NAME="deadly-pool-server"

# Parse args
DO_DEPLOY=false
BUILD_SERVER=false
BUILD_WEB=false
BUILD_LINUX=false
BUILD_WIN=false
HAS_TARGETS=false

for arg in "$@"; do
    case "$arg" in
        --deploy) DO_DEPLOY=true ;;
        server)   BUILD_SERVER=true; HAS_TARGETS=true ;;
        web)      BUILD_WEB=true; HAS_TARGETS=true ;;
        linux)    BUILD_LINUX=true; HAS_TARGETS=true ;;
        win)      BUILD_WIN=true; HAS_TARGETS=true ;;
        all)      BUILD_SERVER=true; BUILD_WEB=true; BUILD_LINUX=true; BUILD_WIN=true; HAS_TARGETS=true ;;
        *)        echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

# Default: server + web
if [ "$HAS_TARGETS" = false ]; then
    BUILD_SERVER=true
    BUILD_WEB=true
fi

# 1. Read version
if [ ! -f VERSION ]; then
    echo "ERROR: VERSION file not found"
    exit 1
fi
VER=$(cat VERSION | tr -d '[:space:]')
echo "=== Deadly Pool v${VER} ==="

# Build target summary
TARGETS=""
$BUILD_SERVER && TARGETS="${TARGETS} server"
$BUILD_WEB && TARGETS="${TARGETS} web"
$BUILD_LINUX && TARGETS="${TARGETS} linux"
$BUILD_WIN && TARGETS="${TARGETS} win"
echo "Targets:${TARGETS}"
echo ""

# 2. Stamp version
sed -i "s/^const VERSION := \".*\"/const VERSION := \"${VER}\"/" scripts/version.gd
echo "[1] Version stamped: ${VER}"

# 3. Export
echo "[2] Exporting..."
$BUILD_LINUX && ./export-linux.sh
$BUILD_WIN && ./export-windows.sh
$BUILD_SERVER && ./export-server.sh
$BUILD_WEB && ./export-web.sh

# 4. Package native clients
mkdir -p dist
if $BUILD_LINUX; then
    rm -f "dist/deadly-pool-${VER}-linux.zip"
    cd export && zip -j "../dist/deadly-pool-${VER}-linux.zip" deadly-pool.x86_64 deadly-pool.sh && cd ..
    echo "  dist/deadly-pool-${VER}-linux.zip   ($(du -h "dist/deadly-pool-${VER}-linux.zip" | cut -f1))"
fi
if $BUILD_WIN; then
    rm -f "dist/deadly-pool-${VER}-windows.zip"
    cd export && zip -j "../dist/deadly-pool-${VER}-windows.zip" deadly-pool.exe && cd ..
    echo "  dist/deadly-pool-${VER}-windows.zip ($(du -h "dist/deadly-pool-${VER}-windows.zip" | cut -f1))"
fi
$BUILD_WEB && echo "  export/web/                         ($(du -sh export/web/ | cut -f1))"

# 5. Generate latest.json (only if building native clients)
if $BUILD_LINUX || $BUILD_WIN; then
    echo "[3] Generating latest.json..."
    cat > dist/latest.json <<EOF
{
  "version": "${VER}",
  "date": "$(date +%Y-%m-%d)",
  "downloads": {
    "linux": "deadly-pool-${VER}-linux.zip",
    "windows": "deadly-pool-${VER}-windows.zip",
    "web": "https://dp.900dfe11a-media.pp.ua/"
  }
}
EOF
fi

echo ""
echo "Build complete!"

if [ "$DO_DEPLOY" = false ]; then
    echo "Run with --deploy to upload to minipc."
    exit 0
fi

# --- Deploy ---
echo ""
echo "=== Deploying to ${REMOTE_HOST} ==="

# Native builds
if $BUILD_LINUX || $BUILD_WIN; then
    echo "Uploading native builds..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_BUILDS_DIR}"
    FILES=""
    $BUILD_LINUX && FILES="$FILES dist/deadly-pool-${VER}-linux.zip"
    $BUILD_WIN && FILES="$FILES dist/deadly-pool-${VER}-windows.zip"
    scp $FILES dist/latest.json "$REMOTE_HOST:${REMOTE_BUILDS_DIR}/"

    # Keep only 3 most recent versions
    echo "Cleaning old builds..."
    ssh "$REMOTE_HOST" 'cd '"${REMOTE_BUILDS_DIR}"' && ls -t *.zip 2>/dev/null | grep linux | tail -n +4 | while read f; do ver=$(echo "$f" | sed "s/deadly-pool-\(.*\)-linux.zip/\1/"); rm -f "deadly-pool-${ver}-linux.zip" "deadly-pool-${ver}-windows.zip"; echo "  removed v${ver}"; done'
fi

# Web client
if $BUILD_WEB; then
    echo "Uploading web client..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_WEB_DIR}"
    scp export/web/* "$REMOTE_HOST:${REMOTE_WEB_DIR}/"
    echo "Web client uploaded."
fi

# Server
if $BUILD_SERVER; then
    echo "Building server Docker image..."
    docker build -t "${IMAGE_NAME}:latest" -t "${IMAGE_NAME}:${VER}" .

    TAR_FILE="/tmp/${IMAGE_NAME}.tar"
    echo "Saving image..."
    docker save "${IMAGE_NAME}:latest" -o "$TAR_FILE"

    echo "Transferring to ${REMOTE_HOST}..."
    scp "$TAR_FILE" "$REMOTE_HOST:/tmp/"

    echo "Loading image and restarting server..."
    ssh "$REMOTE_HOST" bash <<EOF
set -e
docker load -i /tmp/${IMAGE_NAME}.tar
rm /tmp/${IMAGE_NAME}.tar
docker stop ${CONTAINER_NAME} 2>/dev/null || true
docker rm ${CONTAINER_NAME} 2>/dev/null || true
docker run -d \
  --name ${CONTAINER_NAME} \
  --restart unless-stopped \
  --network homelab-apps \
  -p 9876:9876/tcp \
  ${IMAGE_NAME}:latest
docker image prune -f
EOF
    rm -f "$TAR_FILE"
fi

echo ""
echo "=== Deploy complete! ==="
$BUILD_SERVER && echo "  Server:   restarted with v${VER}"
$BUILD_WEB && echo "  Web game: https://dp.900dfe11a-media.pp.ua/"
echo "  Admin:    https://admin-dp.900dfe11a-media.pp.ua/"
($BUILD_LINUX || $BUILD_WIN) && echo "  Builds:   https://sites.900dfe11a-media.pp.ua/deadly-pool/"
