#!/bin/bash
# Rollback script - restores backup files
# Usage: ./rollback.sh

cd "$(dirname "$0")"

echo "Rolling back changes..."

if [ -f "scripts/game_manager.gd.backup" ]; then
    cp scripts/game_manager.gd.backup scripts/game_manager.gd
    echo "✓ Restored scripts/game_manager.gd"
else
    echo "✗ No backup found: scripts/game_manager.gd.backup"
fi

if [ -f "scripts/bot_ai.gd.backup" ]; then
    cp scripts/bot_ai.gd.backup scripts/bot_ai.gd
    echo "✓ Restored scripts/bot_ai.gd"
else
    echo "✗ No backup found: scripts/bot_ai.gd.backup"
fi

if [ -f "scripts/network_manager.gd.backup" ]; then
    cp scripts/network_manager.gd.backup scripts/network_manager.gd
    echo "✓ Restored scripts/network_manager.gd"
else
    echo "✗ No backup found: scripts/network_manager.gd.backup"
fi

echo ""
echo "Rollback complete. Backups are still preserved."
echo "To re-apply changes, you'll need to re-edit the files."
