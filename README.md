# work-cal-sync

Copies work Exchange/O365 calendar events from macOS Calendar.app to a self-hosted CalDAV server (Radicale, Nextcloud, Baikal, etc.).

If you use a self-hosted CalDAV server for your personal calendar and want your work appointments to show up there — without giving a third-party service access to your calendar data — this is for you.

## How it works

- Reads your work Exchange/O365 calendar via **EventKit** — the same framework macOS Calendar.app uses. No Exchange credentials needed in the script; macOS manages authentication via your Internet Account.
- Writes to a dedicated calendar on your CalDAV server using the **caldav** Python library.
- Syncs with `rsync --delete` semantics: creates new events, updates changed ones, deletes cancelled ones.
- Runs every 15 minutes via **launchd**. No need to keep Calendar.app open.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- Python 3.11+ (Homebrew recommended: `brew install python`)
- Your work Exchange/O365 account added to macOS via **System Settings → Internet Accounts**
- A CalDAV server with a dedicated calendar for work events

## Install

```bash
git clone https://github.com/djdead/work-cal-sync.git
cd work-cal-sync
./setup.sh
```

`setup.sh` will:
1. Install Python dependencies (`pyobjc-framework-EventKit`, `caldav`, `keyring`)
2. Copy the script to `~/bin/`
3. Run the interactive setup wizard
4. Install and load a launchd job to sync every 15 minutes

## First-run setup wizard

On first run you will be prompted to:

1. **Choose your work calendar** — detected automatically from Exchange/O365 accounts in Calendar.app
2. **Enter your CalDAV server URL** — e.g. `https://cal.example.com`
3. **Enter your CalDAV username and password** — password is stored in macOS Keychain, never in the config file
4. **Choose your target CalDAV calendar** — fetched from your server so you can pick from a list
5. **Set the sync window** — defaults to 7 days back, 90 days forward

Configuration is saved to `~/.config/work-cal-sync/config.json`. To reconfigure, delete that file and re-run the script.

## Logs

```
~/Library/Logs/work-cal-sync.log
```

## Reconfigure

```bash
rm ~/.config/work-cal-sync/config.json
python3 ~/bin/work-cal-sync.py
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/tel.dead.work-cal-sync.plist
rm ~/Library/LaunchAgents/tel.dead.work-cal-sync.plist
rm ~/bin/work-cal-sync.py
rm -rf ~/.config/work-cal-sync
```

To remove the saved password from Keychain, open **Keychain Access**, search for `work-cal-sync`, and delete the entry.

## Tested with

- macOS 15 Sequoia, M4 Pro
- Exchange Online (O365)
- Radicale 3.x

Other CalDAV servers that follow RFC 4791 should work. Please open an issue if you test with another server.

## Why not just use gSyncIt / CalDAVconnect / etc.?

- **gSyncIt** is Windows-only and syncs via Google Calendar as an intermediary.
- **CalDAVconnect** and similar cloud services route your calendar data through third-party servers — a non-starter if you self-host specifically to control your data.
- **Outlook CalDAV Synchronizer** is Windows-only and dead on new Outlook.
- **macOS Calendar.app** can display both your Exchange and CalDAV calendars simultaneously, but has no built-in way to copy events between accounts.

This script fills that gap: fully local, no cloud intermediary, no credentials stored in plaintext.

## Limitations

- **One-way only** — work → personal CalDAV. Changes made on the CalDAV side are overwritten on the next sync.
- **No attendee/RSVP data** — EventKit exposes attendees but they are not currently written to CalDAV events.
- **Exchange Online only** — EWS/on-premises Exchange is not tested but may work since macOS abstracts the protocol.
- **EWS deprecation** — Microsoft is deprecating EWS for Exchange Online. This script uses EventKit (not EWS directly), so it should be unaffected as long as macOS continues to support Exchange accounts natively.

## Contributing

PRs welcome. Known areas for improvement:

- Attendee/organizer fields
- Support for recurring event exceptions
- Configurable sync interval
- Tests
