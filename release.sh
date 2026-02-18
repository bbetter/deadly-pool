#!/bin/bash
set -e

# Usage: ./release.sh [--deploy]
#   Exports all platforms + web, packages versioned zips, generates latest.json.
#   With --deploy: uploads builds to minipc and restarts the game server.

REMOTE_HOST="andri@192.168.0.108"
REMOTE_BUILDS_DIR="~/caddy/sites/deadly-pool"
REMOTE_WEB_DIR="~/caddy/sites/deadly-pool/web"
IMAGE_NAME="deadly-pool"
CONTAINER_NAME="deadly-pool-server"

DO_DEPLOY=false
for arg in "$@"; do
    if [ "$arg" = "--deploy" ]; then
        DO_DEPLOY=true
    fi
done

# 1. Read version
if [ ! -f VERSION ]; then
    echo "ERROR: VERSION file not found"
    exit 1
fi
VER=$(cat VERSION | tr -d '[:space:]')
echo "=== Deadly Pool v${VER} ==="

# 2. Stamp version into scripts/version.gd
sed -i "s/^const VERSION := \".*\"/const VERSION := \"${VER}\"/" scripts/version.gd
echo "[1/6] Version stamped: ${VER}"

# 3. Export all platforms
echo "[2/6] Exporting builds..."
./export-linux.sh
./export-windows.sh
./export-server.sh
./export-web.sh

# 4. Package client builds
echo "[3/6] Packaging zips..."
mkdir -p dist

# Linux zip
rm -f "dist/deadly-pool-${VER}-linux.zip"
cd export
zip -j "../dist/deadly-pool-${VER}-linux.zip" deadly-pool.x86_64 deadly-pool.sh
cd ..

# Windows zip
rm -f "dist/deadly-pool-${VER}-windows.zip"
cd export
zip -j "../dist/deadly-pool-${VER}-windows.zip" deadly-pool.exe
cd ..

echo "  dist/deadly-pool-${VER}-linux.zip   ($(du -h "dist/deadly-pool-${VER}-linux.zip" | cut -f1))"
echo "  dist/deadly-pool-${VER}-windows.zip ($(du -h "dist/deadly-pool-${VER}-windows.zip" | cut -f1))"
echo "  export/web/                         ($(du -sh export/web/ | cut -f1))"

# 5. Generate latest.json
echo "[4/6] Generating latest.json..."
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

echo "[5/6] Build complete!"
echo ""

if [ "$DO_DEPLOY" = false ]; then
    echo "Run with --deploy to upload to minipc and restart server."
    exit 0
fi

# --- Deploy ---
echo "=== Deploying to ${REMOTE_HOST} ==="

# Upload native builds
echo "Uploading native builds..."
ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_BUILDS_DIR}"
scp dist/deadly-pool-${VER}-linux.zip dist/deadly-pool-${VER}-windows.zip dist/latest.json "$REMOTE_HOST:${REMOTE_BUILDS_DIR}/"
echo "Native builds uploaded."

# Upload web client
echo "Uploading web client..."
ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_WEB_DIR}"
scp export/web/* "$REMOTE_HOST:${REMOTE_WEB_DIR}/"
echo "Web client uploaded."

# Build and deploy server container
echo "Building server Docker image..."
docker build -t "${IMAGE_NAME}:latest" -t "${IMAGE_NAME}:${VER}" .

TAR_FILE="/tmp/${IMAGE_NAME}.tar"
echo "Saving image..."
docker save "${IMAGE_NAME}:latest" -o "$TAR_FILE"

echo "Transferring to ${REMOTE_HOST}..."
scp "$TAR_FILE" "$REMOTE_HOST:/tmp/"

echo "[6/6] Loading image and restarting server..."
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
echo ""
echo "=== Deploy complete! ==="
echo "  Server:   restarted with v${VER}"
echo "  Web game: https://dp.900dfe11a-media.pp.ua/"
echo "  Admin:    https://admin-dp.900dfe11a-media.pp.ua/"
echo "  Builds:   https://sites.900dfe11a-media.pp.ua/deadly-pool/"
