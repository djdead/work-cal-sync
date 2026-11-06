# work-cal-sync

Copies work Exchange/O365 calendar events from macOS Calendar.app to a self-hosted CalDAV server (Radicale, Nextcloud, Baikal, etc.).

If you use a self-hosted CalDAV server for your personal calendar and want your work appointments to show up there — without giving a third-party service access to your calendar data — this is for you.

## How it works

- Reads your work Exchange/O365 calendar via **EventKit** — the same framework macOS Calendar.app uses. No Exchange credentials needed in the script; macOS manages authentication via your Internet Account.
- Writes to a dedicated calendar on your CalDAV server using the **caldav** Python library.
- Syncs with `rsync --delete` semantics: creates new events, updates changed ones, deletes cancelled ones.
- Runs every 15 minutes via **launchd**. No need to keep Calendar.app open.
- Runs in its own Python virtualenv, so it never touches your system or Homebrew site-packages. If Python is upgraded or removed (e.g. `brew upgrade` moves you from 3.13 to 3.14), the launcher notices on the next run and rebuilds the environment automatically.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- Python 3.9+ (Homebrew recommended: `brew install python`)
- Your work Exchange/O365 account added to macOS via **System Settings → Internet Accounts**
- A CalDAV server with a dedicated calendar for work events

## Install

```bash
git clone https://github.com/djdead/work-cal-sync.git
cd work-cal-sync
./setup.sh
```

`setup.sh` will:
1. Copy the script and `requirements.txt` to `~/.local/share/work-cal-sync/`
2. Install the launcher as `~/bin/work-cal-sync`
3. Create a private virtualenv in `~/.local/share/work-cal-sync/venv` and install the dependencies into it
4. Run the interactive setup wizard
5. Install and load a launchd job to sync every 15 minutes

Re-running `setup.sh` upgrades an existing install in place; your config and Keychain password are kept. To use a specific Python, run `PYTHON=/path/to/python3 ./setup.sh`.

### Python upgrades

launchd runs the launcher (`~/bin/work-cal-sync`), not Python directly. Before each sync the launcher checks that the venv can still import its dependencies. If it can't, the launcher rebuilds the venv, trying in order: the Python `setup.sh` used, then Homebrew's `python3`, then `/usr/bin/python3`. The log records the rebuild. If a rebuild fails (for example, you're offline), the next run tries again.

To force a rebuild yourself:

```bash
~/bin/work-cal-sync --rebuild
```

A rebuild can change which Python binary runs the sync. If that happens, macOS may ask again for Calendar access, or the log may show "Calendar access denied". To fix it, allow access in **System Settings → Privacy & Security → Calendars**.

## First-run setup wizard

On first run you will be prompted to:

1. **Choose your work calendar** — detected automatically from Exchange/O365 accounts in Calendar.app
2. **Enter your CalDAV server URL** — e.g. `https://cal.example.com`
3. **Enter your CalDAV username and password** — password is stored in macOS Keychain, never in the config file
4. **Choose your target CalDAV calendar** — fetched from your server so you can pick from a list
5. **Set the sync window** — defaults to 7 days back, 90 days forward
6. **Attendee blocklist** *(optional)* — a comma-separated list of email addresses. The script skips any event with one of these addresses among its attendees. This is useful when you're a member of a group mailbox or distribution list (e.g. `its-team@example.com`) that gets everyone's PTO and out-of-office invites. Those invites land in your Exchange calendar whether or not you decline them, and Calendar.app often keeps showing them after you've deleted them in Outlook. Leave this empty to sync everything.

Configuration is saved to `~/.config/work-cal-sync/config.json`. To reconfigure, delete that file and re-run the script.

You can edit `exclude_attendee_addresses` in `config.json` directly at any time. It's a JSON array of email addresses, and matching ignores case:

```json
"exclude_attendee_addresses": ["its-team@example.com", "all-staff@example.com"]
```

The next sync applies the change. Events already copied to CalDAV that now match the blocklist are deleted from CalDAV on that sync.

## Logs

```
~/Library/Logs/work-cal-sync.log
```

## Failure alerts

Each sync runs unattended, so a broken sync could otherwise fail quietly for weeks. The launcher keeps track of failed runs, and once syncing has been failing for long enough it alerts you:

- a **macOS notification** (shown via Script Editor, so allow notifications for Script Editor in System Settings → Notifications), and
- an optional **hook script** you write, for alerts that reach you somewhere else, like your phone.

An alert fires only when **both** of these are true: syncing has been failing for `alert_after_hours` (default 24), **and** the last `alert_min_failures` runs (default 4) all failed. Requiring both prevents false alarms. One failed run on Friday evening plus one right after waking the Mac on Monday (before Wi-Fi reconnects) isn't three days of failure. While syncing keeps failing, the alert repeats every `alert_repeat_hours` (default 24). Once a sync succeeds again, you get one "recovered" notice.

The alert logic runs in the launcher, not in Python, so it still works when Python itself is broken.

To change the thresholds, add any of these to `~/.config/work-cal-sync/config.json`:

```json
"alert_after_hours": 24,
"alert_min_failures": 4,
"alert_repeat_hours": 24
```

### Alerting to your phone

If `~/.config/work-cal-sync/on-alert` exists and is executable, the launcher runs it with two arguments: the alert kind (`failing`, `recovered` or `test`) and the message. For example, with [ntfy](https://ntfy.sh):

```bash
#!/bin/bash
# ~/.config/work-cal-sync/on-alert
curl -s -H "Title: work-cal-sync $1" -d "$2" https://ntfy.sh/your-private-topic-name
```

Make it executable with `chmod +x ~/.config/work-cal-sync/on-alert`. The hook should finish quickly; launchd stops anything still running after the sync ends. Test every alert channel with:

```bash
~/bin/work-cal-sync --test-alert
```

These alerts can't detect a launchd job that stops running altogether, or a Mac that stays off. If you need to catch that too, have your hook (or a cron job on your server) ping a dead-man's-switch service such as healthchecks.io.

## Reconfigure

```bash
rm ~/.config/work-cal-sync/config.json
~/bin/work-cal-sync
```

## Uninstall

```bash
launchctl bootout gui/$(id -u)/tel.dead.work-cal-sync
rm ~/Library/LaunchAgents/tel.dead.work-cal-sync.plist
rm ~/bin/work-cal-sync
rm -rf ~/.local/share/work-cal-sync
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
- **Recurring events are copied as individual events** — each occurrence inside the sync window becomes its own event on the CalDAV side, rather than one event with a repeat rule. A moved or cancelled occurrence is updated or removed on the next sync, and new occurrences appear as the window rolls forward.
- **No attendee/RSVP data** — EventKit exposes attendees but they are not currently written to CalDAV events.
- **Exchange Online only** — EWS/on-premises Exchange is not tested but may work since macOS abstracts the protocol.
- **EWS deprecation** — Microsoft is deprecating EWS for Exchange Online. This script uses EventKit (not EWS directly), so it should be unaffected as long as macOS continues to support Exchange accounts natively.

## Contributing

PRs welcome. Known areas for improvement:

- Attendee/organizer fields
- Configurable sync interval
- Tests
