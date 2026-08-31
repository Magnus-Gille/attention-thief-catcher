#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/attention-thief-install-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd)"
TEST_REPO="$TEST_ROOT/repo"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_HOME="$TEST_ROOT/home&pipe|slash\\path"
MOCK_SWIFT_LOG="$TEST_ROOT/swift.log"
MOCK_LAUNCHCTL_LOG="$TEST_ROOT/launchctl.log"
MOCK_LAUNCHCTL_STATE="$TEST_ROOT/launchctl.loaded"
MOCK_GUI_DOMAIN="gui/$(id -u)"
MOCK_SERVICE_LABEL="com.magnusgille.attention-thief-catcher"
MOCK_PLIST_PATH="$MOCK_HOME/Library/LaunchAgents/$MOCK_SERVICE_LABEL.plist"
MOCK_PRODUCT_DIR="$TEST_REPO/.build/custom-release"
ORIGINAL_PRODUCT="$REPO_DIR/.build/release/attention-thief-catcher"
ORIGINAL_PRODUCT_PRESENT=false
ORIGINAL_PRODUCT_HASH=""

if [ -f "$ORIGINAL_PRODUCT" ]; then
    ORIGINAL_PRODUCT_PRESENT=true
    ORIGINAL_PRODUCT_HASH="$(shasum -a 256 "$ORIGINAL_PRODUCT" | awk '{print $1}')"
fi

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$MOCK_HOME"
mkdir -p "$TEST_REPO/Scripts" "$TEST_REPO/LaunchAgents" "$TEST_REPO/Sources"
cp "$REPO_DIR/Package.swift" "$TEST_REPO/Package.swift"
cp "$REPO_DIR/Sources/attention-thief-catcher.swift" "$TEST_REPO/Sources/attention-thief-catcher.swift"
cp "$REPO_DIR/Scripts/install.sh" "$TEST_REPO/Scripts/install.sh"
cp "$REPO_DIR/LaunchAgents/com.magnusgille.attention-thief-catcher.plist" \
    "$TEST_REPO/LaunchAgents/com.magnusgille.attention-thief-catcher.plist"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-swift" "$MOCK_BIN/swift"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-swiftc" "$MOCK_BIN/swiftc"
cp "$REPO_DIR/Scripts/tests/fixtures/mock-launchctl" "$MOCK_BIN/launchctl"
chmod 755 "$MOCK_BIN/swift" "$MOCK_BIN/swiftc" "$MOCK_BIN/launchctl"

run_install() {
    local output_log="$1"

    if ! HOME="$MOCK_HOME" \
    PATH="$MOCK_BIN:$PATH" \
    MOCK_REPO="$TEST_REPO" \
    MOCK_SWIFT_LOG="$MOCK_SWIFT_LOG" \
    MOCK_LAUNCHCTL_LOG="$MOCK_LAUNCHCTL_LOG" \
    MOCK_LAUNCHCTL_STATE="$MOCK_LAUNCHCTL_STATE" \
    MOCK_GUI_DOMAIN="$MOCK_GUI_DOMAIN" \
    MOCK_SERVICE_LABEL="$MOCK_SERVICE_LABEL" \
    MOCK_PLIST_PATH="$MOCK_PLIST_PATH" \
    "$TEST_REPO/Scripts/install.sh" >"$output_log" 2>&1; then
        sed -n '1,240p' "$output_log" >&2
        exit 1
    fi
}

run_install "$TEST_ROOT/install-first.log"
run_install "$TEST_ROOT/install-second.log"

INSTALLED_BINARY="$MOCK_HOME/.local/bin/attention-thief-catcher"
INSTALLED_PLIST="$MOCK_PLIST_PATH"
EXPECTED_PRODUCT="$MOCK_PRODUCT_DIR/attention-thief-catcher"

if ! diff -u <(
    printf '%s\n' \
        '---' '--version' \
        '---' 'build' '-c' 'release' '--package-path' "$TEST_REPO" '--product' 'attention-thief-catcher' \
        '---' 'build' '-c' 'release' '--package-path' "$TEST_REPO" '--show-bin-path' \
        '---' '--version' \
        '---' 'build' '-c' 'release' '--package-path' "$TEST_REPO" '--product' 'attention-thief-catcher' \
        '---' 'build' '-c' 'release' '--package-path' "$TEST_REPO" '--show-bin-path'
) "$MOCK_SWIFT_LOG"; then
    echo "FAIL: installer did not invoke SwiftPM with the expected build and bin-path commands" >&2
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

if ! grep -Fqx -- "    <string>$MOCK_HOME/Library/Logs/attention-thief-catcher/stdout.log</string>" \
       <(sed -n '/<key>StandardOutPath<\/key>/,/<\/dict>/p' "$INSTALLED_PLIST") || \
   ! grep -Fqx -- "    <string>$MOCK_HOME/Library/Logs/attention-thief-catcher/stderr.log</string>" \
       <(sed -n '/<key>StandardErrorPath<\/key>/,/<\/dict>/p' "$INSTALLED_PLIST"); then
    echo "FAIL: installer corrupted HOME metacharacters in plist log paths" >&2
    exit 1
fi

EXPECTED_PRINT="print $MOCK_GUI_DOMAIN/$MOCK_SERVICE_LABEL"
EXPECTED_BOOTOUT="bootout $MOCK_GUI_DOMAIN/$MOCK_SERVICE_LABEL"
EXPECTED_BOOTSTRAP="bootstrap $MOCK_GUI_DOMAIN $INSTALLED_PLIST"
if [ "$(sed -n '1p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_PRINT" ] || \
   [ "$(sed -n '2p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_BOOTSTRAP" ] || \
   [ "$(sed -n '3p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_PRINT" ] || \
   [ "$(sed -n '4p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_PRINT" ] || \
   [ "$(sed -n '5p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_BOOTOUT" ] || \
   [ "$(sed -n '6p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_BOOTSTRAP" ] || \
   [ "$(sed -n '7p' "$MOCK_LAUNCHCTL_LOG")" != "$EXPECTED_PRINT" ]; then
    echo "FAIL: installer did not use the expected LaunchAgent label and upgrade sequence" >&2
    sed -n '1,240p' "$MOCK_LAUNCHCTL_LOG" >&2
    exit 1
fi

if [ "$ORIGINAL_PRODUCT_PRESENT" = true ]; then
    if [ ! -f "$ORIGINAL_PRODUCT" ] || \
       [ "$(shasum -a 256 "$ORIGINAL_PRODUCT" | awk '{print $1}')" != "$ORIGINAL_PRODUCT_HASH" ]; then
        echo "FAIL: installer harness modified the original checkout build artifact" >&2
        exit 1
    fi
elif [ -e "$ORIGINAL_PRODUCT" ]; then
    echo "FAIL: installer harness created an original checkout build artifact" >&2
    exit 1
fi

echo "PASS: installer builds and copies the SwiftPM release product in an isolated HOME"
