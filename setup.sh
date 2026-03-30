#!/bin/bash
# work-cal-sync installer
# Installs dependencies, copies the script, and sets up launchd to run every 15 minutes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_LABEL="tel.dead.work-cal-sync"
LOG_DIR="$HOME/Library/Logs"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         work-cal-sync  installer         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Python ────────────────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Install it via Homebrew: brew install python"
    exit 1
fi

PYTHON="$(command -v python3)"
PYTHON_VERSION="$("$PYTHON" --version 2>&1)"
echo "Using $PYTHON_VERSION at $PYTHON"

# ── Dependencies ──────────────────────────────────────────────────────────────
echo ""
echo "Installing Python dependencies..."
"$PYTHON" -m pip install --quiet --break-system-packages \
    pyobjc-framework-EventKit \
    caldav \
    keyring
echo "  ✓ Dependencies installed"

# ── ~/bin ─────────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/work-cal-sync.py" "$INSTALL_DIR/work-cal-sync.py"
chmod +x "$INSTALL_DIR/work-cal-sync.py"
echo "  ✓ Script installed to $INSTALL_DIR/work-cal-sync.py"

# ── launchd plist ─────────────────────────────────────────────────────────────
mkdir -p "$LAUNCH_AGENTS"
mkdir -p "$LOG_DIR"

PLIST_PATH="$LAUNCH_AGENTS/$PLIST_LABEL.plist"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$INSTALL_DIR/work-cal-sync.py</string>
    </array>

    <key>StartInterval</key>
    <integer>900</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/work-cal-sync.log</string>

    <key>StandardErrorPath</key>
    <string>$LOG_DIR/work-cal-sync.log</string>

    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

echo "  ✓ launchd plist installed to $PLIST_PATH"

# ── Unload existing job if running ────────────────────────────────────────────
if launchctl list | grep -q "$PLIST_LABEL" 2>/dev/null; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# ── First run (setup wizard) ──────────────────────────────────────────────────
echo ""
echo "Running first-time setup..."
echo "(Calendar.app may prompt you for permission to access your calendars)"
echo ""
"$PYTHON" "$INSTALL_DIR/work-cal-sync.py"

# ── Load launchd job ──────────────────────────────────────────────────────────
launchctl load "$PLIST_PATH"
echo ""
echo "  ✓ launchd job loaded — will sync every 15 minutes"
echo "  Logs: $LOG_DIR/work-cal-sync.log"
echo ""
echo "Installation complete."
echo ""
echo "To reconfigure, delete ~/.config/work-cal-sync/config.json and run the script again."
echo "To uninstall:  launchctl unload $PLIST_PATH && rm $PLIST_PATH $INSTALL_DIR/work-cal-sync.py"
echo ""
