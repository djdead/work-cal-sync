#!/bin/bash
# work-cal-sync installer
#
# Installs the script and its dependencies into a private virtualenv,
# runs the first-time setup wizard, and loads a launchd job that syncs
# every 15 minutes. Safe to re-run to upgrade an existing install.
#
# Override the Python used with:  PYTHON=/path/to/python3 ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/work-cal-sync"
BIN_DIR="$HOME/bin"
LAUNCHER="$BIN_DIR/work-cal-sync"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_LABEL="tel.dead.work-cal-sync"
PLIST_PATH="$LAUNCH_AGENTS/$PLIST_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/work-cal-sync.log"
DOMAIN="gui/$(id -u)"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         work-cal-sync  installer         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Python ────────────────────────────────────────────────────────────────────
PYTHON="${PYTHON:-$(command -v python3 || true)}"
if [ -z "$PYTHON" ] || ! "$PYTHON" -c 'import sys, venv; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
    echo "ERROR: Python 3.9 or newer is required. Install it with: brew install python"
    exit 1
fi
echo "Using $("$PYTHON" --version 2>&1) at $PYTHON"
echo "(The launcher rebuilds its environment automatically if this Python is upgraded or removed.)"

# ── Stop any existing job while we install ────────────────────────────────────
launchctl bootout "$DOMAIN/$PLIST_LABEL" 2>/dev/null || true

# ── Install files ─────────────────────────────────────────────────────────────
mkdir -p "$APP_DIR" "$BIN_DIR" "$LAUNCH_AGENTS" "$(dirname "$LOG_FILE")"
cp "$SCRIPT_DIR/work-cal-sync.py"  "$APP_DIR/work-cal-sync.py"
cp "$SCRIPT_DIR/requirements.txt"  "$APP_DIR/requirements.txt"
cp "$SCRIPT_DIR/run.sh"            "$LAUNCHER"
chmod +x "$LAUNCHER"
echo "$PYTHON" > "$APP_DIR/python-path"
echo "  ✓ Installed to $APP_DIR"
echo "  ✓ Launcher installed to $LAUNCHER"

# Remove the script left by older installers, which ran it with the system Python.
if [ -f "$BIN_DIR/work-cal-sync.py" ]; then
    rm -f "$BIN_DIR/work-cal-sync.py"
    echo "  ✓ Removed old $BIN_DIR/work-cal-sync.py"
fi

# ── launchd plist ─────────────────────────────────────────────────────────────
sed -e "s|__LAUNCHER__|$LAUNCHER|g" \
    -e "s|__LOG_FILE__|$LOG_FILE|g" \
    -e "s|__LABEL__|$PLIST_LABEL|g" \
    "$SCRIPT_DIR/tel.dead.work-cal-sync.plist" > "$PLIST_PATH"
echo "  ✓ launchd plist installed to $PLIST_PATH"

# ── Build venv + first run (setup wizard on a fresh install) ──────────────────
echo ""
echo "Installing Python dependencies into a private environment..."
echo "(Calendar.app may prompt you for permission to access your calendars)"
echo ""
"$LAUNCHER" --rebuild

# ── Load launchd job ──────────────────────────────────────────────────────────
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
echo ""
echo "  ✓ launchd job loaded; will sync every 15 minutes"
echo "  Logs: $LOG_FILE"
echo ""
echo "Installation complete."
echo ""
echo "To reconfigure:  rm ~/.config/work-cal-sync/config.json && $LAUNCHER"
echo "To uninstall:    see the Uninstall section of README.md"
echo ""
