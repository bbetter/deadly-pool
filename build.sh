#!/bin/bash
set -e

# Usage: ./build.sh <targets...> [--deploy]
#
# Targets (at least one required):
#   server       - Export headless server (release), build Docker image
#   web          - Export web client (release)
#   linux        - Export Linux native client (release)
#   win          - Export Windows native client (release)
#   server-debug - Export headless server (debug), build deadly-pool-debug Docker image
#   web-debug    - Export web client (debug), deploys to web-debug/ dir
#   linux-debug  - Export Linux native client (debug)
#   win-debug    - Export Windows native client (debug)
#   all          - All release targets (server web linux win)
#
# Examples:
#   ./build.sh server web              # build server + web (release)
#   ./build.sh server web --deploy     # build and deploy server + web
#   ./build.sh all --deploy            # build everything (release), deploy
#   ./build.sh web-debug --deploy      # build + deploy debug web client
#   ./build.sh web-debug server-debug --deploy

REMOTE_HOST="andri@192.168.0.108"
REMOTE_BUILDS_DIR="~/caddy/sites/deadly-pool"
REMOTE_WEB_DIR="~/caddy/sites/deadly-pool/web"
IMAGE_NAME="deadly-pool"
IMAGE_NAME_DEBUG="deadly-pool-debug"
CONTAINER_NAME="deadly-pool-server"

# Parse args
DO_DEPLOY=false
BUILD_SERVER=false
BUILD_WEB=false
BUILD_LINUX=false
BUILD_WIN=false
BUILD_SERVER_DEBUG=false
BUILD_WEB_DEBUG=false
BUILD_LINUX_DEBUG=false
BUILD_WIN_DEBUG=false
HAS_TARGETS=false

for arg in "$@"; do
    case "$arg" in
        --deploy)      DO_DEPLOY=true ;;
        server)        BUILD_SERVER=true; HAS_TARGETS=true ;;
        web)           BUILD_WEB=true; HAS_TARGETS=true ;;
        linux)         BUILD_LINUX=true; HAS_TARGETS=true ;;
        win)           BUILD_WIN=true; HAS_TARGETS=true ;;
        server-debug)  BUILD_SERVER_DEBUG=true; HAS_TARGETS=true ;;
        web-debug)     BUILD_WEB_DEBUG=true; HAS_TARGETS=true ;;
        linux-debug)   BUILD_LINUX_DEBUG=true; HAS_TARGETS=true ;;
        win-debug)     BUILD_WIN_DEBUG=true; HAS_TARGETS=true ;;
        all)           BUILD_SERVER=true; BUILD_WEB=true; BUILD_LINUX=true; BUILD_WIN=true; HAS_TARGETS=true ;;
        *)             echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

if [ "$HAS_TARGETS" = false ]; then
    echo "Usage: ./build.sh <targets...> [--deploy]"
    echo ""
    echo "Release targets: server web linux win all"
    echo "Debug targets:   server-debug web-debug linux-debug win-debug"
    echo ""
    echo "Examples:"
    echo "  ./build.sh server web --deploy"
    echo "  ./build.sh all --deploy"
    echo "  ./build.sh web-debug server-debug --deploy"
    exit 1
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
$BUILD_SERVER       && TARGETS="${TARGETS} server"
$BUILD_WEB          && TARGETS="${TARGETS} web"
$BUILD_LINUX        && TARGETS="${TARGETS} linux"
$BUILD_WIN          && TARGETS="${TARGETS} win"
$BUILD_SERVER_DEBUG && TARGETS="${TARGETS} server-debug"
$BUILD_WEB_DEBUG    && TARGETS="${TARGETS} web-debug"
$BUILD_LINUX_DEBUG  && TARGETS="${TARGETS} linux-debug"
$BUILD_WIN_DEBUG    && TARGETS="${TARGETS} win-debug"
echo "Targets:${TARGETS}"
$DO_DEPLOY && echo "Deploy: yes"
echo ""

# 2. Stamp version and export
echo "Exporting..."

# Release exports — stamp clean version
sed -i "s/^const VERSION := \".*\"/const VERSION := \"${VER}\"/" scripts/version.gd
$BUILD_LINUX   && ./export-linux.sh
$BUILD_WIN     && ./export-windows.sh
$BUILD_SERVER  && ./export-server.sh
$BUILD_WEB     && ./export-web.sh

# Debug exports — stamp version with (DEBUG) suffix so clients can identify the build
if $BUILD_LINUX_DEBUG || $BUILD_WIN_DEBUG || $BUILD_SERVER_DEBUG || $BUILD_WEB_DEBUG; then
    sed -i "s/^const VERSION := \".*\"/const VERSION := \"${VER} (DEBUG)\"/" scripts/version.gd
    $BUILD_LINUX_DEBUG  && DEBUG_BUILD=true EXPORT_OUT="export/deadly-pool-debug.x86_64"        ./export-linux.sh
    $BUILD_WIN_DEBUG    && DEBUG_BUILD=true EXPORT_OUT="export/deadly-pool-debug.exe"            ./export-windows.sh
    $BUILD_SERVER_DEBUG && DEBUG_BUILD=true EXPORT_OUT="export/deadly-pool-server-debug.x86_64" ./export-server.sh
    $BUILD_WEB_DEBUG    && DEBUG_BUILD=true EXPORT_DIR="export/web-debug"                        ./export-web.sh
    # Restore clean version stamp so the working tree isn't left dirty
    sed -i "s/^const VERSION := \".*\"/const VERSION := \"${VER}\"/" scripts/version.gd
fi

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
if $BUILD_LINUX_DEBUG; then
    rm -f "dist/deadly-pool-${VER}-linux-debug.zip"
    cd export && zip -j "../dist/deadly-pool-${VER}-linux-debug.zip" deadly-pool-debug.x86_64 deadly-pool.sh && cd ..
    echo "  dist/deadly-pool-${VER}-linux-debug.zip   ($(du -h "dist/deadly-pool-${VER}-linux-debug.zip" | cut -f1))"
fi
if $BUILD_WIN_DEBUG; then
    rm -f "dist/deadly-pool-${VER}-windows-debug.zip"
    cd export && zip -j "../dist/deadly-pool-${VER}-windows-debug.zip" deadly-pool-debug.exe && cd ..
    echo "  dist/deadly-pool-${VER}-windows-debug.zip ($(du -h "dist/deadly-pool-${VER}-windows-debug.zip" | cut -f1))"
fi
$BUILD_WEB       && echo "  export/web/                         ($(du -sh export/web/ | cut -f1))"
$BUILD_WEB_DEBUG && echo "  export/web-debug/                   ($(du -sh export/web-debug/ | cut -f1))"

# 5. Generate latest.json (only if building release native clients)
if $BUILD_LINUX || $BUILD_WIN; then
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
    exit 0
fi

# --- Deploy ---
echo ""
echo "=== Deploying to ${REMOTE_HOST} ==="

# Release native builds
if $BUILD_LINUX || $BUILD_WIN; then
    echo "Uploading native builds..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_BUILDS_DIR}"
    FILES=""
    $BUILD_LINUX && FILES="$FILES dist/deadly-pool-${VER}-linux.zip"
    $BUILD_WIN   && FILES="$FILES dist/deadly-pool-${VER}-windows.zip"
    scp $FILES dist/latest.json "$REMOTE_HOST:${REMOTE_BUILDS_DIR}/"

    # Keep only 3 most recent versions
    echo "Cleaning old builds..."
    ssh "$REMOTE_HOST" 'cd '"${REMOTE_BUILDS_DIR}"' && ls -t *.zip 2>/dev/null | grep linux | tail -n +4 | while read f; do ver=$(echo "$f" | sed "s/deadly-pool-\(.*\)-linux.zip/\1/"); rm -f "deadly-pool-${ver}-linux.zip" "deadly-pool-${ver}-windows.zip"; echo "  removed v${ver}"; done'
fi

# Debug native builds (upload only, no version pruning)
if $BUILD_LINUX_DEBUG || $BUILD_WIN_DEBUG; then
    echo "Uploading debug native builds..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_BUILDS_DIR}"
    FILES=""
    $BUILD_LINUX_DEBUG && FILES="$FILES dist/deadly-pool-${VER}-linux-debug.zip"
    $BUILD_WIN_DEBUG   && FILES="$FILES dist/deadly-pool-${VER}-windows-debug.zip"
    scp $FILES "$REMOTE_HOST:${REMOTE_BUILDS_DIR}/"
fi

# Release web client
if $BUILD_WEB; then
    echo "Uploading web client..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_WEB_DIR}"
    scp export/web/* "$REMOTE_HOST:${REMOTE_WEB_DIR}/"
    echo "Web client uploaded."
fi

# Debug web client (same URL as release — replaces it)
if $BUILD_WEB_DEBUG; then
    echo "Uploading debug web client..."
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_WEB_DIR}"
    scp export/web-debug/* "$REMOTE_HOST:${REMOTE_WEB_DIR}/"
    echo "Debug web client uploaded."
fi

# Release server
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

# Debug server (same container name as release — replaces it)
if $BUILD_SERVER_DEBUG; then
    echo "Building debug server Docker image..."
    docker build \
        --build-arg BINARY=deadly-pool-server-debug \
        -t "${IMAGE_NAME_DEBUG}:latest" -t "${IMAGE_NAME_DEBUG}:${VER}" .

    TAR_FILE="/tmp/${IMAGE_NAME_DEBUG}.tar"
    echo "Saving image..."
    docker save "${IMAGE_NAME_DEBUG}:latest" -o "$TAR_FILE"

    echo "Transferring to ${REMOTE_HOST}..."
    scp "$TAR_FILE" "$REMOTE_HOST:/tmp/"

    echo "Loading image and restarting debug server..."
    ssh "$REMOTE_HOST" bash <<EOF
set -e
docker load -i /tmp/${IMAGE_NAME_DEBUG}.tar
rm /tmp/${IMAGE_NAME_DEBUG}.tar
docker stop ${CONTAINER_NAME} 2>/dev/null || true
docker rm ${CONTAINER_NAME} 2>/dev/null || true
docker run -d \
  --name ${CONTAINER_NAME} \
  --restart unless-stopped \
  --network homelab-apps \
  -p 9876:9876/tcp \
  ${IMAGE_NAME_DEBUG}:latest
docker image prune -f
EOF
    rm -f "$TAR_FILE"
fi

echo ""
echo "=== Deploy complete! ==="
$BUILD_SERVER       && echo "  Server (release):  restarted with v${VER}"
$BUILD_SERVER_DEBUG && echo "  Server (debug):    restarted with v${VER} (DEBUG)  [replaces release]"
$BUILD_WEB          && echo "  Web (release):     https://dp.900dfe11a-media.pp.ua/"
$BUILD_WEB_DEBUG    && echo "  Web (debug):       https://dp.900dfe11a-media.pp.ua/  [replaces release]"
($BUILD_LINUX || $BUILD_WIN) && echo "  Builds:            https://sites.900dfe11a-media.pp.ua/deadly-pool/"
echo "  Admin:             https://admin-dp.900dfe11a-media.pp.ua/"
