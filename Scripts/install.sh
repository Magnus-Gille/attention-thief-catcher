#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY_NAME="attention-thief-catcher"
INSTALL_DIR="$HOME/.local/bin"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
SERVICE_LABEL="com.magnusgille.attention-thief-catcher"
PLIST_NAME="$SERVICE_LABEL.plist"
PLIST_SRC="$REPO_DIR/LaunchAgents/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
GUI_UID=$(id -u)
SERVICE_DOMAIN="gui/$GUI_UID"
SERVICE_TARGET="$SERVICE_DOMAIN/$SERVICE_LABEL"

# Prerequisite checks
echo "==> Checking prerequisites..."
if ! command -v swift &>/dev/null; then
    echo "ERROR: swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

if ! swift --version &>/dev/null; then
    echo "ERROR: Swift toolchain not working. You may need to accept the Xcode license:"
    echo "  sudo xcodebuild -license accept"
    exit 1
fi

echo "==> Compiling $BINARY_NAME..."
mkdir -p "$INSTALL_DIR" "$(dirname "$PLIST_DST")"
swift build -c release --package-path "$REPO_DIR" --product "$BINARY_NAME"
SWIFT_BIN_PATH="$(swift build -c release --package-path "$REPO_DIR" --show-bin-path)"
if [ -z "$SWIFT_BIN_PATH" ]; then
    echo "ERROR: SwiftPM did not report its release product directory"
    exit 1
fi
SWIFT_PRODUCT="$SWIFT_BIN_PATH/$BINARY_NAME"
if [ ! -x "$SWIFT_PRODUCT" ]; then
    echo "ERROR: SwiftPM did not produce the expected release product: $SWIFT_PRODUCT"
    exit 1
fi
cp "$SWIFT_PRODUCT" "$BINARY_PATH"
chmod 755 "$BINARY_PATH"
codesign -s - "$BINARY_PATH" 2>/dev/null || true
echo "    Installed binary to $BINARY_PATH"

# Unload existing agent if present (ignore errors)
if launchctl print "$SERVICE_TARGET" &>/dev/null; then
    echo "==> Unloading existing agent..."
    launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
    sleep 1
fi

echo "==> Installing launch agent plist..."
# Expand ~ in the plist to the actual home directory. Escape sed replacement
# metacharacters because HOME may contain &, |, or backslashes.
escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

INSTALL_DIR_ESCAPED="$(escape_sed_replacement "$INSTALL_DIR")"
HOME_ESCAPED="$(escape_sed_replacement "$HOME")"
sed -e "s|~/.local/bin|$INSTALL_DIR_ESCAPED|g" \
    -e "s|~/Library|$HOME_ESCAPED/Library|g" "$PLIST_SRC" > "$PLIST_DST"
echo "    Installed plist to $PLIST_DST"

echo "==> Loading agent..."
launchctl bootstrap "$SERVICE_DOMAIN" "$PLIST_DST"

echo "==> Done. Verifying..."
sleep 1
if launchctl print "$SERVICE_TARGET" &>/dev/null; then
    echo "    Agent is running."
else
    echo "    WARNING: Agent may not be running. Check:"
    echo "    launchctl print $SERVICE_TARGET"
fi

echo ""
echo "Logs will appear in ~/Library/Logs/attention-thief-catcher/"
echo "Analyze with: python3 $REPO_DIR/Scripts/analyze.py"
