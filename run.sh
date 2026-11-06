#!/bin/bash
# work-cal-sync launcher.
#
# Installed by setup.sh as ~/bin/work-cal-sync and run by launchd.
# Keeps the script's private virtualenv healthy, then runs the sync.
#
# Why this exists: a venv is tied to the Python it was created from. When
# Homebrew upgrades Python (e.g. 3.13 -> 3.14) the venv's interpreter and
# installed packages disappear out from under it. Before each run this
# launcher checks that the venv can still import its dependencies, and
# if it can't, rebuilds it from whatever Python is installed now.
#
# Usage:
#   work-cal-sync              run a sync (first run starts the setup wizard)
#   work-cal-sync --rebuild    force a venv rebuild, then run a sync
#
# Must stay compatible with macOS's bash 3.2.

set -u

APP_DIR="${WORK_CAL_SYNC_HOME:-$HOME/.local/share/work-cal-sync}"
VENV="$APP_DIR/venv"
SCRIPT="$APP_DIR/work-cal-sync.py"
REQS="$APP_DIR/requirements.txt"
PY_HINT_FILE="$APP_DIR/python-path"
LOCK="$APP_DIR/.rebuild.lock"
IMPORT_CHECK='import EventKit, caldav, icalendar, keyring'

# launchd starts jobs with a minimal PATH; make Homebrew visible.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%H:%M:%S') launcher: $*" >&2; }

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

rebuild_venv() {
    local py
    if ! py="$(find_python)"; then
        log "ERROR: no usable python3 (3.9 or newer) found. Install one with: brew install python"
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
    log "ERROR: failed to build Python environment; will retry next run."
    return 1
}

if [ ! -f "$SCRIPT" ] || [ ! -f "$REQS" ]; then
    log "ERROR: $APP_DIR is incomplete. Re-run setup.sh from the work-cal-sync repo."
    exit 1
fi

force=0
if [ "${1:-}" = "--rebuild" ]; then
    force=1
    shift
fi

if [ "$force" = 1 ]; then
    rebuild_venv || exit 1
elif ! venv_ok; then
    log "Python environment missing or broken (Python upgraded?); rebuilding."
    rebuild_venv || exit 1
fi

exec "$VENV/bin/python" "$SCRIPT" "$@"
