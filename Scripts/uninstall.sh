#!/usr/bin/env bash
set -euo pipefail

BINARY_NAME="attention-thief-catcher"
INSTALL_DIR="$HOME/.local/bin"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
PLIST_NAME="com.magnusgille.attention-thief-catcher.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
GUI_UID=$(id -u)

echo "==> Unloading agent..."
if launchctl print "gui/$GUI_UID/$PLIST_NAME" &>/dev/null; then
    launchctl bootout "gui/$GUI_UID/$PLIST_NAME" 2>/dev/null || true
    echo "    Agent unloaded."
else
    echo "    Agent was not loaded."
fi

echo "==> Removing binary..."
if [ -f "$BINARY_PATH" ]; then
    rm "$BINARY_PATH"
    echo "    Removed $BINARY_PATH"
else
    echo "    Binary not found at $BINARY_PATH"
fi

echo "==> Removing plist..."
if [ -f "$PLIST_DST" ]; then
    rm "$PLIST_DST"
    echo "    Removed $PLIST_DST"
else
    echo "    Plist not found at $PLIST_DST"
fi

echo ""
echo "==> Done. Logs preserved at ~/Library/Logs/attention-thief-catcher/"
echo "    To remove logs: rm -rf ~/Library/Logs/attention-thief-catcher/"
