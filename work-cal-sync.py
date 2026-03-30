#!/usr/bin/env python3
"""
work-cal-sync — Copy work O365/Exchange calendar events from macOS Calendar.app to a CalDAV server.

Reads the work Exchange/O365 calendar via EventKit (macOS manages auth).
Writes to a dedicated CalDAV calendar. Syncs with rsync --delete semantics:
  - Events in work but not CalDAV → create
  - Events in both but work is newer → update
  - Events in CalDAV but not work → delete

On first run, an interactive setup wizard configures everything and saves to
~/.config/work-cal-sync/config.json. Password is stored in macOS Keychain.

Requirements:
    pip3 install --break-system-packages pyobjc-framework-EventKit caldav keyring

See setup.sh for automated install.
"""

import sys
import json
import threading
import datetime
import logging
import getpass
import uuid
import os

CONFIG_PATH = os.path.expanduser("~/.config/work-cal-sync/config.json")
KEYCHAIN_SERVICE = "work-cal-sync"

try:
    import EventKit
    import Foundation
except ImportError:
    sys.exit("Missing pyobjc. Run: pip3 install --break-system-packages pyobjc-framework-EventKit")

try:
    import caldav
    from icalendar import Calendar as iCal, Event as iEvent
except ImportError:
    sys.exit("Missing caldav. Run: pip3 install --break-system-packages caldav")

try:
    import keyring
except ImportError:
    sys.exit("Missing keyring. Run: pip3 install --break-system-packages keyring")


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ── Config ────────────────────────────────────────────────────────────────────

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return None
    with open(CONFIG_PATH) as f:
        return json.load(f)


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_PATH), mode=0o700, exist_ok=True)
    with open(CONFIG_PATH, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)


# ── Keychain ──────────────────────────────────────────────────────────────────

def get_password(username):
    return keyring.get_password(KEYCHAIN_SERVICE, username)


def set_password(username, password):
    keyring.set_password(KEYCHAIN_SERVICE, username, password)


# ── EventKit ──────────────────────────────────────────────────────────────────

def request_eventkit_access(store):
    auth = EventKit.EKEventStore.authorizationStatusForEntityType_(EventKit.EKEntityTypeEvent)
    if auth == 3:
        return True
    if auth in (1, 2):
        log.error(
            "Calendar access denied. "
            "Go to System Settings > Privacy & Security > Calendars and allow this script."
        )
        return False

    done = threading.Event()
    granted_box = [False]

    def callback(granted, error):
        granted_box[0] = bool(granted)
        done.set()

    if hasattr(store, 'requestFullAccessToEventsWithCompletion_'):
        store.requestFullAccessToEventsWithCompletion_(callback)
    else:
        store.requestAccessToEntityType_completion_(EventKit.EKEntityTypeEvent, callback)

    done.wait(timeout=30)
    return granted_box[0]


def get_exchange_calendars(store):
    """Return list of (title, source_title, EKCalendar) for Exchange/O365 calendars.
    macOS registers Exchange/O365 accounts as EKSourceTypeMobileMe (type 1).
    Excludes Birthdays and Holidays calendars.
    """
    calendars = store.calendarsForEntityType_(EventKit.EKEntityTypeEvent)
    exclude = {'birthdays', 'holidays', 'united states holidays'}
    return [
        (c.title(), c.source().title(), c)
        for c in calendars
        if c.source().sourceType() == 1
        and c.title().lower() not in exclude
    ]


def nsdate_to_unix(nsdate):
    if nsdate is None:
        return 0
    return nsdate.timeIntervalSince1970()


def nsdate_to_dt(nsdate, all_day=False):
    if nsdate is None:
        return None
    ts = nsdate.timeIntervalSince1970()
    dt = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)
    return dt.date() if all_day else dt


def fetch_work_events(store, calendar, days_back, days_forward):
    """Return {ext_id: EKEvent} for events in the sync window."""
    now   = datetime.datetime.now()
    start = now - datetime.timedelta(days=days_back)
    end   = now + datetime.timedelta(days=days_forward)

    ns_start = Foundation.NSDate.dateWithTimeIntervalSince1970_(start.timestamp())
    ns_end   = Foundation.NSDate.dateWithTimeIntervalSince1970_(end.timestamp())

    predicate = store.predicateForEventsWithStartDate_endDate_calendars_(
        ns_start, ns_end, [calendar]
    )
    ek_events = store.eventsMatchingPredicate_(predicate) or []

    result = {}
    for ev in ek_events:
        ext_id = ev.calendarItemExternalIdentifier()
        if ext_id:
            result[str(ext_id)] = ev
    return result


# ── iCalendar building ────────────────────────────────────────────────────────

def make_ical(ek_event, uid=None):
    cal = iCal()
    cal.add('prodid', '-//work-cal-sync//EN')
    cal.add('version', '2.0')

    ev = iEvent()
    ev.add('uid', uid or str(uuid.uuid4()))
    ev.add('summary', str(ek_event.title() or '(No title)'))

    all_day = bool(ek_event.isAllDay())
    start   = nsdate_to_dt(ek_event.startDate(), all_day)
    end     = nsdate_to_dt(ek_event.endDate(),   all_day)
    if start:
        ev.add('dtstart', start)
    if end:
        ev.add('dtend', end)

    if ek_event.notes():
        ev.add('description', str(ek_event.notes()))
    if ek_event.location():
        ev.add('location', str(ek_event.location()))

    ev.add('X-WORK-CAL-ID',       str(ek_event.calendarItemExternalIdentifier()))
    ev.add('X-WORK-CAL-MODIFIED', str(int(nsdate_to_unix(ek_event.lastModifiedDate()))))

    cal.add_component(ev)
    return cal.to_ical().decode('utf-8')


# ── CalDAV ────────────────────────────────────────────────────────────────────

def get_caldav_calendars(url, username, password):
    """Return list of (name, url_string) for calendars on the CalDAV server."""
    try:
        client = caldav.DAVClient(url=url, username=username, password=password)
        principal = client.principal()
        calendars = principal.calendars()
        return [(c.name, str(c.url)) for c in calendars if c.name]
    except Exception as e:
        raise RuntimeError(f"Could not connect to CalDAV server: {e}")


def fetch_radicale_events(caldav_calendar):
    """Return {work_ext_id: (caldav_event, uid, mod_ts)} for all events."""
    managed = {}
    try:
        all_events = caldav_calendar.events()
    except Exception as e:
        log.error("Failed to fetch CalDAV events: %s", e)
        return managed

    for ev in all_events:
        try:
            cal = iCal.from_ical(ev.data)
            for component in cal.walk():
                if component.name != 'VEVENT':
                    continue
                work_id = str(component.get('X-WORK-CAL-ID', ''))
                uid     = str(component.get('uid', ''))
                mod     = int(str(component.get('X-WORK-CAL-MODIFIED', 0)))
                if work_id:
                    managed[work_id] = (ev, uid, mod)
        except Exception as e:
            log.warning("Could not parse CalDAV event: %s", e)

    return managed


# ── Setup wizard ──────────────────────────────────────────────────────────────

def pick(prompt, options, label_fn):
    """Display a numbered list and return the chosen item."""
    print(f"\n{prompt}")
    for i, opt in enumerate(options, 1):
        print(f"  {i}) {label_fn(opt)}")
    while True:
        raw = input("Enter number: ").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1]
        print(f"  Please enter a number between 1 and {len(options)}.")


def setup_wizard(store):
    print("\n╔══════════════════════════════════════════╗")
    print("║         work-cal-sync  first-run setup   ║")
    print("╚══════════════════════════════════════════╝")
    print("\nThis will only run once. Settings are saved to:")
    print(f"  {CONFIG_PATH}")
    print("Your password will be stored in macOS Keychain.\n")

    # ── Exchange calendar ──────────────────────────────────────────────────
    print("Detecting Exchange/O365 calendars in Calendar.app...")
    exchange_cals = get_exchange_calendars(store)
    if not exchange_cals:
        sys.exit(
            "No Exchange/O365 calendars found in Calendar.app.\n"
            "Add your work account via System Settings > Internet Accounts first."
        )

    chosen_ek = pick(
        "Which calendar contains your work events?",
        exchange_cals,
        lambda c: f"{c[0]}  ({c[1]})",
    )
    work_calendar_name   = chosen_ek[0]
    work_calendar_source = chosen_ek[1]
    print(f"  ✓ Work calendar: {work_calendar_name} ({work_calendar_source})")

    # ── CalDAV server ──────────────────────────────────────────────────────
    print()
    caldav_server = input("CalDAV server URL (e.g. https://cal.example.com): ").strip().rstrip('/')
    caldav_user   = input("CalDAV username: ").strip()
    caldav_pass   = getpass.getpass("CalDAV password: ")

    print("\nConnecting to CalDAV server and listing calendars...")
    try:
        caldav_calendars = get_caldav_calendars(caldav_server, caldav_user, caldav_pass)
    except RuntimeError as e:
        sys.exit(str(e))

    if not caldav_calendars:
        sys.exit("No calendars found on the CalDAV server. Create a target calendar first.")

    chosen_cal = pick(
        "Which CalDAV calendar should work events be copied into?",
        caldav_calendars,
        lambda c: f"{c[0]}  ({c[1]})",
    )
    caldav_calendar_url = chosen_cal[1]
    print(f"  ✓ Target calendar: {chosen_cal[0]}")

    # ── Sync window ────────────────────────────────────────────────────────
    print()
    def prompt_int(msg, default):
        raw = input(f"{msg} [default {default}]: ").strip()
        return int(raw) if raw.isdigit() else default

    days_back    = prompt_int("How many days back to sync", 7)
    days_forward = prompt_int("How many days forward to sync", 90)

    # ── Save ───────────────────────────────────────────────────────────────
    cfg = {
        "work_calendar_name":   work_calendar_name,
        "caldav_server":        caldav_server,
        "caldav_username":      caldav_user,
        "caldav_calendar_url":  caldav_calendar_url,
        "days_back":            days_back,
        "days_forward":         days_forward,
    }
    save_config(cfg)
    set_password(caldav_user, caldav_pass)

    print(f"\n  ✓ Config saved to {CONFIG_PATH}")
    print("  ✓ Password saved to macOS Keychain")
    print("\nSetup complete. Running first sync...\n")
    return cfg


# ── Sync ──────────────────────────────────────────────────────────────────────

def sync(store, cfg):
    calendars = store.calendarsForEntityType_(EventKit.EKEntityTypeEvent)
    ek_calendar = next(
        (c for c in calendars if c.title() == cfg['work_calendar_name']),
        None
    )
    if ek_calendar is None:
        sys.exit(f"Work calendar '{cfg['work_calendar_name']}' not found in Calendar.app. "
                 f"Re-run setup by deleting {CONFIG_PATH}.")

    log.info("Work calendar: %s  (%s)", ek_calendar.title(), ek_calendar.source().title())

    password = get_password(cfg['caldav_username'])
    if not password:
        password = getpass.getpass(f"CalDAV password for {cfg['caldav_username']}: ")
        set_password(cfg['caldav_username'], password)

    try:
        client = caldav.DAVClient(
            url=cfg['caldav_calendar_url'],
            username=cfg['caldav_username'],
            password=password,
        )
        caldav_calendar = caldav.Calendar(client=client, url=cfg['caldav_calendar_url'])
    except Exception as e:
        log.error("Failed to connect to CalDAV server: %s", e)
        sys.exit(1)

    log.info("Fetching work events from Calendar.app...")
    work_events = fetch_work_events(
        store, ek_calendar,
        cfg.get('days_back', 7),
        cfg.get('days_forward', 90),
    )
    log.info("Found %d work events in sync window.", len(work_events))

    log.info("Fetching events from CalDAV...")
    caldav_events = fetch_radicale_events(caldav_calendar)
    log.info("Found %d events in CalDAV.", len(caldav_events))

    created = updated = deleted = skipped = 0

    for work_id, ek_ev in work_events.items():
        mod_ts = int(nsdate_to_unix(ek_ev.lastModifiedDate()))
        if work_id not in caldav_events:
            try:
                caldav_calendar.add_event(make_ical(ek_ev))
                log.info("  Created: %s", ek_ev.title())
                created += 1
            except Exception as e:
                log.error("  Failed to create '%s': %s", ek_ev.title(), e)
        else:
            rad_ev, existing_uid, stored_mod = caldav_events[work_id]
            if mod_ts > stored_mod:
                try:
                    rad_ev.data = make_ical(ek_ev, uid=existing_uid)
                    rad_ev.save()
                    log.info("  Updated: %s", ek_ev.title())
                    updated += 1
                except Exception as e:
                    log.error("  Failed to update '%s': %s", ek_ev.title(), e)
            else:
                skipped += 1

    for work_id, (rad_ev, uid, mod) in caldav_events.items():
        if work_id not in work_events:
            try:
                rad_ev.delete()
                log.info("  Deleted (gone from work calendar)")
                deleted += 1
            except Exception as e:
                log.error("  Failed to delete event: %s", e)

    log.info("Done — created: %d  updated: %d  deleted: %d  unchanged: %d",
             created, updated, deleted, skipped)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    store = EventKit.EKEventStore.alloc().init()

    if not request_eventkit_access(store):
        sys.exit(1)

    cfg = load_config()
    if cfg is None:
        cfg = setup_wizard(store)

    sync(store, cfg)


if __name__ == '__main__':
    main()
