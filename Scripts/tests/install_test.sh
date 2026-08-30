#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/attention-thief-install-test.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_HOME="$TEST_ROOT/home"
MOCK_SWIFT_LOG="$TEST_ROOT/swift.log"
MOCK_LAUNCHCTL_LOG="$TEST_ROOT/launchctl.log"
MOCK_LAUNCHCTL_STATE="$TEST_ROOT/launchctl.loaded"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$MOCK_HOME"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-swift" "$MOCK_BIN/swift"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-swiftc" "$MOCK_BIN/swiftc"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-launchctl" "$MOCK_BIN/launchctl"
chmod 755 "$MOCK_BIN/swift" "$MOCK_BIN/swiftc" "$MOCK_BIN/launchctl"

if ! HOME="$MOCK_HOME" \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_REPO="$REPO_DIR" \
    MOCK_SWIFT_LOG="$MOCK_SWIFT_LOG" \
    MOCK_LAUNCHCTL_LOG="$MOCK_LAUNCHCTL_LOG" \
    MOCK_LAUNCHCTL_STATE="$MOCK_LAUNCHCTL_STATE" \
    "$REPO_DIR/Scripts/install.sh" >"$TEST_ROOT/install.log" 2>&1; then
    sed -n '1,240p' "$TEST_ROOT/install.log" >&2
    exit 1
fi

INSTALLED_BINARY="$MOCK_HOME/.local/bin/attention-thief-catcher"
INSTALLED_PLIST="$MOCK_HOME/Library/LaunchAgents/com.magnusgille.attention-thief-catcher.plist"
EXPECTED_PRODUCT="$REPO_DIR/.build/release/attention-thief-catcher"

if ! grep -Fqx -- "build" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "-c" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "release" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "--package-path" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "$REPO_DIR" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "--product" "$MOCK_SWIFT_LOG" || \
   ! grep -Fqx -- "attention-thief-catcher" "$MOCK_SWIFT_LOG"; then
    echo "FAIL: installer did not invoke SwiftPM release build with the expected product" >&2
    sed -n '1,240p' "$MOCK_SWIFT_LOG" >&2
    exit 1
fi

if [ ! -x "$EXPECTED_PRODUCT" ] || [ ! -x "$INSTALLED_BINARY" ]; then
    echo "FAIL: expected SwiftPM product or installed binary is missing" >&2
    exit 1
fi

if ! cmp -s "$EXPECTED_PRODUCT" "$INSTALLED_BINARY"; then
    echo "FAIL: installer did not copy the exact SwiftPM release product" >&2
    exit 1
fi

if [ ! -f "$INSTALLED_PLIST" ] || \
   ! grep -Fqx -- "    <string>$MOCK_HOME/.local/bin/attention-thief-catcher</string>" \
       <(sed -n '/<key>Program<\/key>/,/<\/dict>/p' "$INSTALLED_PLIST"); then
    echo "FAIL: installer did not render the LaunchAgent plist into the isolated HOME" >&2
    exit 1
fi

if ! grep -Fqx -- "bootstrap gui/$(id -u) $INSTALLED_PLIST" \
    "$MOCK_LAUNCHCTL_LOG"; then
    echo "FAIL: installer did not bootstrap the expected LaunchAgent label" >&2
    sed -n '1,240p' "$MOCK_LAUNCHCTL_LOG" >&2
    exit 1
fi

echo "PASS: installer builds and copies the SwiftPM release product in an isolated HOME"
