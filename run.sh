#!/bin/bash
# work-cal-sync launcher.
#
# Installed by setup.sh as ~/bin/work-cal-sync and run by launchd.
# Keeps the script's private virtualenv healthy, runs the sync, and raises
# an alert if syncing keeps failing.
#
# Why this exists: a venv is tied to the Python it was created from. When
# Homebrew upgrades Python (e.g. 3.13 -> 3.14) the venv's interpreter and
# installed packages disappear out from under it. Before each run this
# launcher checks that the venv can still import its dependencies, and
# if it can't, rebuilds it from whatever Python is installed now.
#
# Failure alerts live here, not in the Python script, so they still fire
# when Python itself is what's broken.
#
# Usage:
#   work-cal-sync              run a sync (first run starts the setup wizard)
#   work-cal-sync --rebuild    force a venv rebuild, then run a sync
#   work-cal-sync --test-alert send a test alert through every channel and exit
#
# Must stay compatible with macOS's bash 3.2.

set -u

APP_DIR="${WORK_CAL_SYNC_HOME:-$HOME/.local/share/work-cal-sync}"
CONFIG_DIR="$HOME/.config/work-cal-sync"
CONFIG_FILE="$CONFIG_DIR/config.json"
ALERT_HOOK="$CONFIG_DIR/on-alert"
LOG_FILE="$HOME/Library/Logs/work-cal-sync.log"
VENV="$APP_DIR/venv"
SCRIPT="$APP_DIR/work-cal-sync.py"
REQS="$APP_DIR/requirements.txt"
PY_HINT_FILE="$APP_DIR/python-path"
LOCK="$APP_DIR/.rebuild.lock"
STATE_DIR="$APP_DIR/state"
IMPORT_CHECK='import EventKit, caldav, icalendar, keyring'

# launchd starts jobs with a minimal PATH; make Homebrew visible.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%H:%M:%S') launcher: $*" >&2; }

# ── Alerting ──────────────────────────────────────────────────────────────────
#
# State, in $STATE_DIR:
#   failing-since   epoch of the first failure in the current failure streak
#   failure-count   number of consecutive failed runs
#   last-alert      epoch of the last "failing" alert sent
#   last-error      short reason for the most recent failure

# Read an integer setting from config.json without Python (Python may be the
# thing that's broken). Falls back to the default if the key is missing.
config_int() {
    local key="$1" default="$2" val=""
    if [ -f "$CONFIG_FILE" ]; then
        val="$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CONFIG_FILE" | head -n 1)"
    fi
    echo "${val:-$default}"
}

read_state() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

# Format an epoch timestamp (BSD date on macOS, GNU date elsewhere).
fmt_time() {
    date -r "$1" '+%a %b %-d %H:%M' 2>/dev/null \
        || date -d "@$1" '+%a %b %-d %H:%M' 2>/dev/null \
        || echo "$1"
}

# Send an alert through every available channel.
#   $1 = failing | recovered | test     $2 = message
send_alert() {
    local kind="$1" msg="$2"
    log "ALERT ($kind): $msg"

    # macOS notification. Arguments are passed via argv, not interpolated
    # into the AppleScript, so quotes in the message can't break it.
    if command -v osascript >/dev/null 2>&1; then
        osascript - "work-cal-sync" "$msg" >/dev/null 2>&1 <<'APPLESCRIPT' || log "warning: could not show macOS notification"
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"
end run
APPLESCRIPT
    fi

    # Optional user hook, e.g. to push to your phone via ntfy/Pushover/email.
    if [ -x "$ALERT_HOOK" ]; then
        "$ALERT_HOOK" "$kind" "$msg" || log "warning: $ALERT_HOOK exited with status $?"
    fi
}

record_success() {
    [ -d "$STATE_DIR" ] || return 0
    if [ -n "$(read_state last-alert)" ]; then
        local since; since="$(read_state failing-since)"
        send_alert recovered "Syncing again after failing since $(fmt_time "${since:-0}")."
    fi
    rm -f "$STATE_DIR/failing-since" "$STATE_DIR/failure-count" \
          "$STATE_DIR/last-alert" "$STATE_DIR/last-error"
}

# Record a failed run, and alert if the failure streak is long enough.
#   $1 = short reason
record_failure() {
    local reason="$1" now since count last_alert
    mkdir -p "$STATE_DIR"
    now="$(date +%s)"

    since="$(read_state failing-since)"
    [ -n "$since" ] || { since="$now"; echo "$since" > "$STATE_DIR/failing-since"; }
    count="$(read_state failure-count)"
    count=$(( ${count:-0} + 1 ))
    echo "$count" > "$STATE_DIR/failure-count"
    echo "$reason" > "$STATE_DIR/last-error"

    local after_h min_fail repeat_h
    after_h="$(config_int alert_after_hours 24)"
    min_fail="$(config_int alert_min_failures 4)"
    repeat_h="$(config_int alert_repeat_hours 24)"

    local elapsed=$(( now - since ))
    log "Run failed ($reason). Failing for $(( elapsed / 3600 ))h, $count run(s) in a row."

    # Both conditions, so a single failure before a weekend asleep plus one
    # right after wake (before Wi-Fi is up) doesn't count as days of failure.
    if [ "$elapsed" -ge $(( after_h * 3600 )) ] && [ "$count" -ge "$min_fail" ]; then
        last_alert="$(read_state last-alert)"
        if [ -z "$last_alert" ] || [ $(( now - last_alert )) -ge $(( repeat_h * 3600 )) ]; then
            send_alert failing "Calendar sync has been failing for $(( elapsed / 3600 )) hours ($count runs). Last error: $reason. See $LOG_FILE"
            echo "$now" > "$STATE_DIR/last-alert"
        fi
    fi
}

fail() {
    record_failure "$1"
    exit 1
}

# ── Python environment ────────────────────────────────────────────────────────

venv_ok() {
    [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "$IMPORT_CHECK" >/dev/null 2>&1
}

# Print the first usable Python >= 3.9. Preference order:
#   1. $WORK_CAL_SYNC_PYTHON (explicit override)
#   2. the interpreter recorded by setup.sh
#   3. Homebrew (Apple Silicon, then Intel), then Apple's /usr/bin/python3
find_python() {
    local candidates=()
    [ -n "${WORK_CAL_SYNC_PYTHON:-}" ] && candidates+=("$WORK_CAL_SYNC_PYTHON")
    [ -f "$PY_HINT_FILE" ] && candidates+=("$(cat "$PY_HINT_FILE")")
    candidates+=(/opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3)

    local py
    for py in "${candidates[@]}"; do
        if [ -x "$py" ] && "$py" -c 'import sys, venv; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
            echo "$py"
            return 0
        fi
    done
    return 1
}

acquire_lock() {
    # Clear a lock left behind by a rebuild that crashed more than 30 minutes ago.
    if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null
    fi
    mkdir "$LOCK" 2>/dev/null
}

# Returns 0 on success, 1 on failure (with REBUILD_ERROR set), and exits 0 if
# another process is already rebuilding.
rebuild_venv() {
    local py
    if ! py="$(find_python)"; then
        REBUILD_ERROR="no usable python3 (3.9 or newer) found; install one with: brew install python"
        log "ERROR: $REBUILD_ERROR"
        return 1
    fi

    if ! acquire_lock; then
        log "Another rebuild is in progress; skipping this run."
        exit 0
    fi
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT

    log "Building Python environment with $py ($("$py" --version 2>&1))..."
    rm -rf "$VENV"
    if "$py" -m venv "$VENV" \
        && { "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --upgrade pip \
             || log "warning: could not upgrade pip; continuing with bundled version"; } \
        && "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check -r "$REQS" \
        && "$VENV/bin/python" -c "$IMPORT_CHECK"
    then
        log "Python environment ready."
        rmdir "$LOCK" 2>/dev/null
        trap - EXIT
        return 0
    fi

    # Leave nothing half-built behind, so the next run tries again (e.g. if
    # the network was down this time).
    rm -rf "$VENV"
    REBUILD_ERROR="could not build the Python environment with $py"
    log "ERROR: $REBUILD_ERROR; will retry next run."
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --test-alert)
        send_alert test "Test alert from work-cal-sync. If you can read this, failure alerts will reach you."
        exit 0
        ;;
esac

if [ ! -f "$SCRIPT" ] || [ ! -f "$REQS" ]; then
    log "ERROR: $APP_DIR is incomplete. Re-run setup.sh from the work-cal-sync repo."
    fail "installation is incomplete; re-run setup.sh"
fi

force=0
if [ "${1:-}" = "--rebuild" ]; then
    force=1
    shift
fi

REBUILD_ERROR=""
if [ "$force" = 1 ]; then
    rebuild_venv || fail "$REBUILD_ERROR"
elif ! venv_ok; then
    log "Python environment missing or broken (Python upgraded?); rebuilding."
    rebuild_venv || fail "$REBUILD_ERROR"
fi

# Copy the script's stderr (its log) to a file as well, so a failure alert can
# quote the actual error. stdout is left alone for the setup wizard's prompts.
mkdir -p "$STATE_DIR"
RUN_STDERR="$STATE_DIR/last-run-stderr"
{ "$VENV/bin/python" "$SCRIPT" "$@" 2>&1 1>&3 | tee "$RUN_STDERR" >&2; status=${PIPESTATUS[0]}; } 3>&1

if [ "$status" -eq 0 ]; then
    record_success
else
    # Prefer the first logged ERROR line (the root cause); otherwise the last
    # line of output (the sys.exit message, or the exception ending a traceback).
    err="$(grep ' ERROR ' "$RUN_STDERR" | head -n 1)"
    [ -n "$err" ] || err="$(grep -v '^[[:space:]]*$' "$RUN_STDERR" | tail -n 1)"
    err="$(echo "$err" | sed 's/^[0-9:]* ERROR //' | cut -c1-200)"
    fail "${err:-sync exited with status $status}"
fi
