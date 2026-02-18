#!/bin/bash
# Backup script - creates backup files before making changes
# Usage: ./backup.sh

cd "$(dirname "$0")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Creating backups..."

for file in scripts/game_manager.gd scripts/bot_ai.gd scripts/network_manager.gd; do
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup"
        echo "✓ Backed up $file"
    else
        echo "✗ File not found: $file"
    fi
done

echo ""
echo "Backups created with .backup extension"
echo "To rollback: ./rollback.sh"
