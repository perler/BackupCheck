#!/usr/bin/env python3
"""
pause-offline-checks.py - Mute healthchecks.io alerts for offline machines.

Removes notification channels from backup monitoring checks for workstations/notebooks
confirmed offline in Atera RMM, preventing false alerts from machines that are
legitimately powered off (weekends, holidays, travel). Channels are restored
automatically when the machine comes back online in Atera.

Unlike HC's "pause" feature (which gets undone by any ping), muting channels
lets the backup monitor continue sending pings without triggering alerts.

Usage:
    python3 pause-offline-checks.py [--dry-run] [--verbose]
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

# File to track which checks we've muted (so we know to restore them)
# Check locations in order: /cron/data (persistent mount), script dir, /tmp (fallback)
_script_dir = os.path.dirname(os.path.abspath(__file__))
for _data_dir in ["/cron/data", _script_dir, "/tmp"]:
    if os.path.isdir(_data_dir) and os.access(_data_dir, os.W_OK):
        MUTED_FILE = os.path.join(_data_dir, ".muted-checks.json")
        break


def load_env(env_path):
    """Load key=value pairs from a .env file."""
    env = {}
    if not os.path.exists(env_path):
        return env
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split("=", 1)
                if len(parts) == 2:
                    env[parts[0].strip()] = parts[1].strip()
    return env


def load_muted_checks():
    """Load the set of currently muted check slugs."""
    if not os.path.exists(MUTED_FILE):
        return set()
    try:
        with open(MUTED_FILE) as f:
            data = json.load(f)
            return set(data.get("muted", []))
    except (json.JSONDecodeError, OSError):
        return set()


def save_muted_checks(muted_set):
    """Save the set of currently muted check slugs."""
    with open(MUTED_FILE, "w") as f:
        json.dump({"muted": sorted(muted_set)}, f, indent=2)


def api_request(url, headers, method="GET", data=None):
    """Make an HTTP request and return parsed JSON."""
    req = urllib.request.Request(url, headers=headers, method=method, data=data)
    req.add_header("User-Agent", "BackupCheck/0.7.0")
    with urllib.request.urlopen(req) as resp:
        body = resp.read().decode()
        if not body:
            return {}
        return json.loads(body)


def fetch_all_atera_agents(api_key, verbose=False):
    """Fetch all agents from Atera, handling pagination (50 per page)."""
    agents = []
    page = 1
    headers = {"X-API-KEY": api_key, "Accept": "application/json"}

    while True:
        url = f"https://app.atera.com/api/v3/agents?page={page}&itemsInPage=50"
        if verbose:
            print(f"  Fetching Atera agents page {page}...")
        data = api_request(url, headers)
        items = data.get("items", [])
        if not items:
            break
        agents.extend(items)
        if data.get("totalPages", page) <= page:
            break
        page += 1

    return agents


def normalize_agent_name(name):
    """Normalize Atera agent name to match HC slug format.

    Strips common suffixes: .FRITZ.BOX, .local, .domain.tld
    Strips parenthetical suffixes like (ctl)
    """
    name = name.strip()
    name = re.sub(r"\s*\([^)]*\)\s*$", "", name)
    name = re.sub(r"\.[A-Za-z].*$", "", name)
    return name.lower()


def get_company_code(customer_name):
    """Extract company code from Atera customer name."""
    if not customer_name:
        return None
    return customer_name.split()[0].lower()


def build_atera_lookup(agents, verbose=False):
    """Build a lookup dict from Atera agents keyed by '{companyCode}-{machineName}'."""
    lookup = {}
    for agent in agents:
        code = get_company_code(agent.get("CustomerName", ""))
        name = normalize_agent_name(agent.get("AgentName", ""))
        if not code or not name:
            continue
        key = f"{code}-{name}"
        last_seen = agent.get("LastSeen") or agent.get("Modified")
        online = agent.get("Online", False)
        lookup[key] = {
            "online": online,
            "last_seen": last_seen,
            "agent_name": agent.get("AgentName", ""),
            "customer": agent.get("CustomerName", ""),
        }
    if verbose:
        print(f"  Built Atera lookup with {len(lookup)} agents")
    return lookup


def fetch_hc_checks(api_key, verbose=False):
    """Fetch all checks from healthchecks.io Management API."""
    headers = {"X-Api-Key": api_key}
    url = "https://healthchecks.io/api/v1/checks/"
    if verbose:
        print("  Fetching healthchecks.io checks...")
    data = api_request(url, headers)
    checks = data.get("checks", [])
    if verbose:
        print(f"  Found {len(checks)} checks")
    return checks


def is_eligible_device(slug):
    """Check if a check slug represents a workstation or notebook (not server)."""
    parts = slug.split("-", 1)
    if len(parts) < 2:
        return False
    device = parts[1]
    return device.startswith("wks") or device.startswith("nb")


def parse_hc_datetime(dt_str):
    """Parse a healthchecks.io datetime string to a timezone-aware datetime."""
    if not dt_str:
        return None
    dt_str = dt_str.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(dt_str)
    except (ValueError, TypeError):
        return None


def seconds_since(dt_str):
    """Return seconds elapsed since the given datetime string, or None."""
    dt = parse_hc_datetime(dt_str)
    if not dt:
        return None
    now = datetime.now(timezone.utc)
    return (now - dt).total_seconds()


def parse_atera_datetime(dt_str):
    """Parse Atera datetime formats to seconds-since-now."""
    if not dt_str:
        return None

    match = re.search(r"/Date\((\d+)([+-]\d+)?\)/", dt_str)
    if match:
        ms = int(match.group(1))
        dt = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
        now = datetime.now(timezone.utc)
        return (now - dt).total_seconds()

    return seconds_since(dt_str)


def mute_check(check, api_key, dry_run=False, verbose=False):
    """Mute a check by removing all notification channels."""
    update_url = check.get("update_url")
    if not update_url:
        if verbose:
            print(f"    No update_url for {check['slug']}, skipping")
        return False

    if dry_run:
        return True

    try:
        headers = {"X-Api-Key": api_key, "Content-Type": "application/json"}
        data = json.dumps({"channels": ""}).encode()
        api_request(update_url, headers, method="POST", data=data)
        return True
    except urllib.error.URLError as e:
        print(f"    Error muting {check['slug']}: {e}")
        return False


def unmute_check(check, api_key, dry_run=False, verbose=False):
    """Unmute a check by restoring all notification channels."""
    update_url = check.get("update_url")
    if not update_url:
        if verbose:
            print(f"    No update_url for {check['slug']}, skipping")
        return False

    if dry_run:
        return True

    try:
        headers = {"X-Api-Key": api_key, "Content-Type": "application/json"}
        data = json.dumps({"channels": "*"}).encode()
        api_request(update_url, headers, method="POST", data=data)
        return True
    except urllib.error.URLError as e:
        print(f"    Error unmuting {check['slug']}: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Mute healthchecks.io alerts for offline machines detected via Atera RMM."
    )
    parser.add_argument("--dry-run", action="store_true", help="Show what would be changed without making changes")
    parser.add_argument("--verbose", action="store_true", help="Show detailed output")
    args = parser.parse_args()

    # Load environment
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env = load_env(os.path.join(script_dir, ".env"))

    hc_api_key = env.get("HC_API_KEY")
    atera_api_key = env.get("ATERA_API_KEY")

    if not hc_api_key:
        print("ERROR: HC_API_KEY not found in .env")
        sys.exit(1)
    if not atera_api_key:
        print("ERROR: ATERA_API_KEY not found in .env")
        sys.exit(1)

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] pause-offline-checks {'(DRY RUN)' if args.dry_run else ''}")
    print("-" * 60)

    # Fetch data from both APIs
    try:
        agents = fetch_all_atera_agents(atera_api_key, verbose=args.verbose)
        print(f"Atera: {len(agents)} agents fetched")
    except Exception as e:
        print(f"ERROR: Failed to fetch Atera agents: {e}")
        sys.exit(1)

    try:
        checks = fetch_hc_checks(hc_api_key, verbose=args.verbose)
        print(f"Healthchecks: {len(checks)} checks fetched")
    except Exception as e:
        print(f"ERROR: Failed to fetch healthchecks.io checks: {e}")
        sys.exit(1)

    # Build lookup
    atera_lookup = build_atera_lookup(agents, verbose=args.verbose)

    # Load currently muted checks
    muted_checks = load_muted_checks()
    if muted_checks and args.verbose:
        print(f"  Currently muted: {len(muted_checks)} checks")

    # Process checks
    muted_count = 0
    unmuted_count = 0
    skipped_count = 0
    no_match_count = 0
    already_muted = 0
    ineligible_count = 0

    for check in checks:
        slug = check.get("slug", "")
        status = check.get("status", "")
        timeout = check.get("timeout", 0)
        last_ping = check.get("last_ping")
        is_currently_muted = slug in muted_checks

        # Skip non-eligible device types (servers, unknown)
        if not is_eligible_device(slug):
            ineligible_count += 1
            if args.verbose:
                print(f"  [{slug}] skip - not wks/nb device")
            continue

        # Find matching Atera agent
        agent_info = atera_lookup.get(slug)
        if not agent_info:
            no_match_count += 1
            if args.verbose:
                print(f"  [{slug}] no matching Atera agent")
            continue

        # Check if agent is online
        agent_online = agent_info["online"]

        # UNMUTE path: agent is back online and check was muted by us
        if agent_online and is_currently_muted:
            action = "WOULD UNMUTE" if args.dry_run else "UNMUTING"
            print(f"  [{slug}] {action} - agent back online")
            if unmute_check(check, hc_api_key, dry_run=args.dry_run, verbose=args.verbose):
                unmuted_count += 1
                muted_checks.discard(slug)
            continue

        if agent_online:
            skipped_count += 1
            if args.verbose:
                print(f"  [{slug}] agent online in Atera")
            continue

        # Agent is offline
        if is_currently_muted:
            already_muted += 1
            if args.verbose:
                print(f"  [{slug}] already muted")
            continue

        # Agent is offline - check how long
        agent_last_seen = agent_info.get("last_seen")
        agent_offline_secs = parse_atera_datetime(agent_last_seen)

        # Calculate mute threshold: period minus 1 day
        mute_threshold = timeout - 86400
        if mute_threshold <= 0:
            skipped_count += 1
            if args.verbose:
                print(f"  [{slug}] skip - period too short ({timeout}s) for mute threshold")
            continue

        # Two paths: already-down checks vs preventive mute
        is_down = status == "down"

        if is_down:
            # Already-down: mute if Atera agent unseen for >24h
            if agent_offline_secs is None or agent_offline_secs < 86400:
                skipped_count += 1
                if args.verbose:
                    offline_hrs = round(agent_offline_secs / 3600, 1) if agent_offline_secs else "?"
                    print(f"  [{slug}] down but agent seen {offline_hrs}h ago (<24h), skipping")
                continue

            offline_days = round(agent_offline_secs / 86400, 1)
            action = "WOULD MUTE" if args.dry_run else "MUTING"
            print(f"  [{slug}] {action} (down) - agent offline {offline_days}d")
        else:
            # Preventive: mute before check expires (period - 1 day threshold)
            if agent_offline_secs is None or agent_offline_secs < mute_threshold:
                skipped_count += 1
                if args.verbose:
                    offline_hrs = round(agent_offline_secs / 3600, 1) if agent_offline_secs else "?"
                    threshold_hrs = round(mute_threshold / 3600, 1)
                    print(f"  [{slug}] offline {offline_hrs}h < threshold {threshold_hrs}h")
                continue

            # Dual-signal safety: also check no recent HC ping (>24h)
            ping_age_secs = seconds_since(last_ping)
            if ping_age_secs is not None and ping_age_secs < 86400:
                skipped_count += 1
                if args.verbose:
                    print(f"  [{slug}] recent ping ({round(ping_age_secs / 3600, 1)}h ago), skipping")
                continue

            offline_days = round(agent_offline_secs / 86400, 1)
            threshold_days = round(mute_threshold / 86400, 1)
            action = "WOULD MUTE" if args.dry_run else "MUTING"
            print(f"  [{slug}] {action} - offline {offline_days}d (threshold: {threshold_days}d)")

        if mute_check(check, hc_api_key, dry_run=args.dry_run, verbose=args.verbose):
            muted_count += 1
            muted_checks.add(slug)

    # Save muted state
    if not args.dry_run:
        save_muted_checks(muted_checks)

    # Summary
    print()
    print(f"Summary: {muted_count} muted, {unmuted_count} unmuted, {skipped_count} skipped, "
          f"{no_match_count} unmatched, {already_muted} already muted, "
          f"{ineligible_count} ineligible (srv/other)")


if __name__ == "__main__":
    main()
