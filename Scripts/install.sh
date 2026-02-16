#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="attention-thief-catcher"
INSTALL_DIR="$HOME/.local/bin"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
PLIST_NAME="com.magnusgille.attention-thief-catcher.plist"
PLIST_SRC="$REPO_DIR/LaunchAgents/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SWIFT_SRC="$REPO_DIR/Sources/attention-thief-catcher.swift"
GUI_UID=$(id -u)

echo "==> Compiling $BINARY_NAME..."
mkdir -p "$INSTALL_DIR"
swiftc -O -o "$BINARY_PATH" "$SWIFT_SRC" -framework AppKit
echo "    Installed binary to $BINARY_PATH"

# Unload existing agent if present (ignore errors)
if launchctl print "gui/$GUI_UID/$PLIST_NAME" &>/dev/null; then
    echo "==> Unloading existing agent..."
    launchctl bootout "gui/$GUI_UID/$PLIST_NAME" 2>/dev/null || true
    sleep 1
fi

echo "==> Installing launch agent plist..."
# Expand ~ in the plist to the actual home directory
sed "s|~/.local/bin|$INSTALL_DIR|g" "$PLIST_SRC" > "$PLIST_DST"
echo "    Installed plist to $PLIST_DST"

echo "==> Loading agent..."
launchctl bootstrap "gui/$GUI_UID" "$PLIST_DST"

echo "==> Done. Verifying..."
sleep 1
if launchctl print "gui/$GUI_UID/$PLIST_NAME" &>/dev/null; then
    echo "    Agent is running."
else
    echo "    WARNING: Agent may not be running. Check:"
    echo "    launchctl print gui/$GUI_UID/$PLIST_NAME"
fi

echo ""
echo "Logs will appear in ~/Library/Logs/attention-thief-catcher/"
echo "Analyze with: python3 $REPO_DIR/Scripts/analyze.py"
