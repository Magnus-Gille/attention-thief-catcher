#!/usr/bin/env bash
set -euo pipefail

SERVICE_LABEL="com.magnusgille.attention-thief-catcher"
LOG_DIR="$HOME/Library/Logs/attention-thief-catcher"
STALE_THRESHOLD_MINUTES=5

DAEMON_RUNNING=false
LOG_STALE=false
SLEEP_SUPPRESSED=false

# ── (a) Daemon status ─────────────────────────────────────────────────────────
echo "==> Daemon status..."
LAUNCHCTL_OUTPUT=$(launchctl print "gui/$UID/$SERVICE_LABEL" 2>&1) || true

if echo "$LAUNCHCTL_OUTPUT" | grep -qE "could not find service|No such process|does not exist"; then
    echo "    Status  : NOT LOADED"
    echo "    Hint    : Run Scripts/install.sh to load the daemon."
else
    DAEMON_PID=$(echo "$LAUNCHCTL_OUTPUT" | grep -E '^\s+pid\s*=' | grep -oE '[0-9]+' || true)
    if [ -n "$DAEMON_PID" ]; then
        echo "    Status  : RUNNING"
        echo "    PID     : $DAEMON_PID"
        DAEMON_RUNNING=true
    else
        echo "    Status  : LOADED (no active PID — may be exiting or crashed)"
    fi
fi

# ── (b) Log freshness ─────────────────────────────────────────────────────────
echo ""
echo "==> Log freshness..."
if [ ! -d "$LOG_DIR" ]; then
    echo "    No log directory found at $LOG_DIR"
    LOG_STALE=true
else
    # Find the newest .ndjson file
    NEWEST_LOG=$(find "$LOG_DIR" -name "*.ndjson" -type f -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null | head -1 || true)

    if [ -z "$NEWEST_LOG" ]; then
        echo "    No .ndjson log files found in $LOG_DIR"
        LOG_STALE=true
    else
        LOG_MTIME_HUMAN=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$NEWEST_LOG" 2>/dev/null || true)
        LOG_MTIME_EPOCH=$(stat -f "%m" "$NEWEST_LOG" 2>/dev/null || true)
        NOW_EPOCH=$(date +%s)
        STALE_MINUTES=$(( (NOW_EPOCH - LOG_MTIME_EPOCH) / 60 ))

        echo "    Newest log : $NEWEST_LOG"
        echo "    Last write : $LOG_MTIME_HUMAN  (${STALE_MINUTES}m ago)"

        # Check if the last event is a sleep/screen-sleep event
        LAST_EVENT=$(grep -v '^[[:space:]]*$' "$NEWEST_LOG" 2>/dev/null | tail -1 || true)
        if [ -n "$LAST_EVENT" ]; then
            LAST_EVENT_TYPE=$(echo "$LAST_EVENT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('event', ''))
except Exception:
    print('')
" 2>/dev/null || true)
        else
            LAST_EVENT_TYPE=""
        fi

        if [ "$LAST_EVENT_TYPE" = "SYSTEM_WILL_SLEEP" ] || [ "$LAST_EVENT_TYPE" = "SCREENS_DID_SLEEP" ]; then
            echo "    Freshness  : (suppressed — last event indicates system is sleeping)"
            SLEEP_SUPPRESSED=true
        elif [ "$STALE_MINUTES" -gt "$STALE_THRESHOLD_MINUTES" ]; then
            echo "    Freshness  : WARNING — log not updated in ${STALE_MINUTES} minutes"
            LOG_STALE=true
        else
            echo "    Freshness  : OK"
        fi
    fi
fi

# ── (c) Disk usage ────────────────────────────────────────────────────────────
echo ""
echo "==> Log directory disk usage..."
if [ ! -d "$LOG_DIR" ]; then
    echo "    No log directory found at $LOG_DIR"
else
    DU_OUTPUT=$(du -sh "$LOG_DIR" 2>/dev/null || true)
    echo "    $DU_OUTPUT"
fi

# ── (d) Recent DAEMON_START events ────────────────────────────────────────────
echo ""
echo "==> Recent DAEMON_START events..."
if [ ! -d "$LOG_DIR" ]; then
    echo "    No log directory found at $LOG_DIR"
else
    DAEMON_START_LINES=$(find "$LOG_DIR" -name "*.ndjson" -type f -print0 2>/dev/null \
        | xargs -0 ls -t 2>/dev/null \
        | xargs grep -h '"DAEMON_START"' 2>/dev/null | head -5 || true)

    if [ -z "$DAEMON_START_LINES" ]; then
        echo "    No DAEMON_START events found"
    else
        START_COUNT=$(echo "$DAEMON_START_LINES" | wc -l | tr -d ' ')
        INDEX=0
        while IFS= read -r line; do
            INDEX=$((INDEX + 1))
            TS=$(echo "$line" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('timestamp', '(unknown timestamp)'))
except Exception:
    print('(parse error)')
" 2>/dev/null || echo "(parse error)")
            echo "    $INDEX. $TS"
        done <<< "$DAEMON_START_LINES"

        if [ "$START_COUNT" -gt 1 ]; then
            echo "    ($START_COUNT restarts detected — review if unexpected)"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Summary"

VERDICT="OK"
if [ "$DAEMON_RUNNING" = false ]; then
    VERDICT="ATTENTION NEEDED — daemon is not running"
elif [ "$LOG_STALE" = true ] && [ "$SLEEP_SUPPRESSED" = false ]; then
    VERDICT="ATTENTION NEEDED — log is stale and daemon may have stopped logging"
fi

echo "    $VERDICT"
