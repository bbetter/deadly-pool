#!/bin/bash
# Quick local test: launches two clients that auto-create and auto-join a room.
# Usage: ./test_local.sh [server_ip]
#   Default server_ip: dp.900dfe11a-media.pp.ua
#
# NOTE: The server must be running the same version as the client.
#       If you get "Invalid packet received" errors, rebuild and redeploy the server too.

IP="${1:-dp.900dfe11a-media.pp.ua}"
EXE="./export/deadly-pool.x86_64"
CODE_FILE="/tmp/deadly-pool-room-code.txt"

if [ ! -f "$EXE" ]; then
    echo "ERROR: $EXE not found. Export the project first."
    exit 1
fi

# Clean stale room code
rm -f "$CODE_FILE"

cleanup() {
    kill $PID1 $PID2 2>/dev/null
    rm -f "$CODE_FILE"
}
trap cleanup EXIT INT TERM

echo "Connecting to server: $IP"
echo "Starting client 1 (Alice, creates room)..."
$EXE -- --name=Alice --ip="$IP" --auto-create --auto-start &
PID1=$!

echo "Waiting for room code..."
ROOM_CODE=""
for i in $(seq 1 30); do
    if [ -f "$CODE_FILE" ]; then
        ROOM_CODE=$(cat "$CODE_FILE")
        if [ -n "$ROOM_CODE" ]; then
            break
        fi
    fi
    sleep 0.5
done

if [ -z "$ROOM_CODE" ]; then
    echo "ERROR: Timed out waiting for room code (15s)."
    echo "Make sure the server at $IP is running and up to date."
    exit 1
fi

echo "Room code: $ROOM_CODE"
sleep 1
echo "Starting client 2 (Bob, joins room)..."
$EXE -- --name=Bob --ip="$IP" --auto-join="$ROOM_CODE" &
PID2=$!

echo "Both clients running (PIDs: $PID1, $PID2)"
echo "Press Ctrl+C to kill both."
wait
