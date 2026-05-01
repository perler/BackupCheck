"""
BackupCheck Coordinator API

Receives backup scan results from Windows monitors, correlates with Atera RMM
agent status, and pings healthchecks.io with the final verdict.

Decision matrix:
  Backup OK   + Agent Online  → ping HC success
  Backup OK   + Agent Offline → ping HC success (backup was recent)
  Backup FAIL + Agent Online  → ping HC fail (real problem!)
  Backup FAIL + Agent Offline → skip ping (machine legitimately off)
"""

import hashlib
import json
import logging
import os
import re
import sqlite3
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import Flask, abort, g, jsonify, request, send_from_directory

app = Flask(__name__)

# Configuration
DB_PATH = os.environ.get("COORDINATOR_DB", "/data/coordinator.db")
RELEASES_DIR = Path(os.environ.get("COORDINATOR_RELEASES", "/releases"))
HC_API_KEY = os.environ.get("HC_API_KEY", "")
HC_PING_KEY = os.environ.get("HC_PING_KEY", "")
ATERA_API_KEY = os.environ.get("ATERA_API_KEY", "")
API_KEYS = [k.strip() for k in os.environ.get("COORDINATOR_API_KEYS", "").split(",") if k.strip()]
ADMIN_KEY = os.environ.get("COORDINATOR_ADMIN_KEY", "")
ATERA_CACHE_SECONDS = int(os.environ.get("ATERA_CACHE_SECONDS", "900"))  # 15 min
COORDINATOR_VERSION = "2.2.0"
VALID_CHANNELS = ("stable", "canary")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("coordinator")


# --- Database ---

def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA journal_mode=WAL")
    return g.db


@app.teardown_appcontext
def close_db(exception):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    """Create tables if they don't exist."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            company_id TEXT NOT NULL,
            machine_name TEXT NOT NULL,
            healthy INTEGER NOT NULL,
            backup_age REAL,
            backup_count INTEGER DEFAULT 0,
            message TEXT,
            monitor_version TEXT,
            monitor_channel TEXT,
            reported_at TEXT NOT NULL,
            processed_at TEXT,
            verdict TEXT
        );

        CREATE TABLE IF NOT EXISTS atera_cache (
            agent_key TEXT PRIMARY KEY,
            online INTEGER NOT NULL,
            last_seen TEXT,
            agent_name TEXT,
            customer TEXT,
            cached_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_reports_company_machine
            ON reports (company_id, machine_name);
        CREATE INDEX IF NOT EXISTS idx_reports_reported_at
            ON reports (reported_at);
    """)
    # Migration: add monitor_channel to existing tables (silently no-op if present)
    try:
        conn.execute("ALTER TABLE reports ADD COLUMN monitor_channel TEXT")
    except sqlite3.OperationalError:
        pass
    conn.commit()
    conn.close()


# --- Auth ---

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        key = request.headers.get("X-API-Key", "")
        if not API_KEYS:
            # No keys configured = no auth required (dev mode)
            return f(*args, **kwargs)
        if key not in API_KEYS:
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


def require_admin_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not ADMIN_KEY:
            return jsonify({"error": "admin key not configured"}), 503
        if request.headers.get("X-Admin-Key", "") != ADMIN_KEY:
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated


# --- Atera ---

def _atera_request(url):
    """Make a request to the Atera API."""
    headers = {"X-API-KEY": ATERA_API_KEY, "Accept": "application/json"}
    req = urllib.request.Request(url, headers=headers)
    req.add_header("User-Agent", f"BackupCheck-Coordinator/{COORDINATOR_VERSION}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def _normalize_agent_name(name):
    """Normalize Atera agent name to match HC slug format."""
    name = name.strip()
    name = re.sub(r"\s*\([^)]*\)\s*$", "", name)
    name = re.sub(r"\.[A-Za-z].*$", "", name)
    return name.lower()


def _get_company_code(customer_name):
    """Extract company code from Atera customer name."""
    if not customer_name:
        return None
    return customer_name.split()[0].lower()


def refresh_atera_cache(db):
    """Fetch all Atera agents and update the cache."""
    log.info("Refreshing Atera agent cache...")
    agents = []
    page = 1

    while True:
        url = f"https://app.atera.com/api/v3/agents?page={page}&itemsInPage=50"
        data = _atera_request(url)
        items = data.get("items", [])
        if not items:
            break
        agents.extend(items)
        if data.get("totalPages", page) <= page:
            break
        page += 1

    now = datetime.now(timezone.utc).isoformat()
    for agent in agents:
        code = _get_company_code(agent.get("CustomerName", ""))
        name = _normalize_agent_name(agent.get("AgentName", ""))
        if not code or not name:
            continue
        key = f"{code}-{name}"
        db.execute(
            """INSERT OR REPLACE INTO atera_cache
               (agent_key, online, last_seen, agent_name, customer, cached_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                key,
                1 if agent.get("Online", False) else 0,
                agent.get("LastSeen") or agent.get("Modified"),
                agent.get("AgentName", ""),
                agent.get("CustomerName", ""),
                now,
            ),
        )
    db.commit()
    log.info(f"Cached {len(agents)} Atera agents")


def get_agent_status(db, agent_key):
    """Get agent online status from cache. Returns dict or None."""
    row = db.execute(
        "SELECT * FROM atera_cache WHERE agent_key = ?", (agent_key,)
    ).fetchone()
    if not row:
        return None
    return dict(row)


def is_cache_stale(db):
    """Check if the Atera cache needs refreshing."""
    row = db.execute(
        "SELECT MAX(cached_at) as latest FROM atera_cache"
    ).fetchone()
    if not row or not row["latest"]:
        return True
    cached_at = datetime.fromisoformat(row["latest"].replace("Z", "+00:00"))
    age = (datetime.now(timezone.utc) - cached_at).total_seconds()
    return age > ATERA_CACHE_SECONDS


# --- Healthchecks.io ---

def ping_hc(slug, success, message=""):
    """Send a ping to healthchecks.io."""
    if not HC_PING_KEY:
        log.warning(f"No HC_PING_KEY, skipping ping for {slug}")
        return False

    suffix = "" if success else "/fail"
    url = f"https://hc-ping.com/{HC_PING_KEY}/{slug}{suffix}?create=1"

    try:
        data = message.encode("utf-8") if message else None
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "text/plain")
        req.add_header("User-Agent", f"BackupCheck-Coordinator/{COORDINATOR_VERSION}")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception as e:
        log.error(f"HC ping failed for {slug}: {e}")
        return False


# --- API Routes ---

@app.route("/api/report", methods=["POST"])
@require_api_key
def receive_report():
    """Receive backup scan results from a Windows monitor."""
    data = request.get_json()
    if not data:
        return jsonify({"error": "JSON body required"}), 400

    company_id = data.get("companyId", "").lower()
    version = data.get("version", "unknown")
    channel = data.get("channel", "stable")
    machines = data.get("machines", [])

    if not company_id:
        return jsonify({"error": "companyId required"}), 400
    if not machines:
        return jsonify({"error": "machines array required"}), 400

    db = get_db()
    now = datetime.now(timezone.utc).isoformat()

    # Refresh Atera cache if stale
    if ATERA_API_KEY and is_cache_stale(db):
        try:
            refresh_atera_cache(db)
        except Exception as e:
            log.error(f"Atera cache refresh failed: {e}")
            # Continue with stale cache rather than failing

    results = []
    for machine in machines:
        name = machine.get("name", "").lower()
        healthy = machine.get("healthy", False)
        backup_age = machine.get("backupAge")
        backup_count = machine.get("backupCount", 0)
        message = machine.get("message", "")

        slug = f"{company_id}-{name}"

        # Store the report
        db.execute(
            """INSERT INTO reports
               (company_id, machine_name, healthy, backup_age, backup_count,
                message, monitor_version, monitor_channel, reported_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (company_id, name, 1 if healthy else 0, backup_age,
             backup_count, message, version, channel, now),
        )

        # Apply decision matrix
        agent = get_agent_status(db, slug)
        agent_online = agent["online"] if agent else None

        if healthy:
            # Backup OK → always ping success
            verdict = "success"
            ping_hc(slug, True, f"[Coordinator] {message}")
        elif agent_online is None:
            # No Atera data → fall through, send the failure
            verdict = "fail_no_agent_data"
            ping_hc(slug, False, f"[Coordinator] {message}")
            log.warning(f"{slug}: no Atera data, forwarding failure")
        elif agent_online:
            # Backup missing + agent online → real problem
            verdict = "fail"
            ping_hc(slug, False, f"[Coordinator] {message}")
        else:
            # Backup missing + agent offline → skip (machine legitimately off)
            verdict = "skipped_offline"
            log.info(f"{slug}: skipping ping - agent offline, backup missing")

        # Update report with verdict
        db.execute(
            """UPDATE reports SET processed_at = ?, verdict = ?
               WHERE company_id = ? AND machine_name = ? AND reported_at = ?""",
            (datetime.now(timezone.utc).isoformat(), verdict,
             company_id, name, now),
        )

        results.append({"name": name, "slug": slug, "verdict": verdict})

    db.commit()

    log.info(
        f"Report from {company_id} (v{version}/{channel}): "
        f"{len(machines)} machines, "
        f"{sum(1 for r in results if r['verdict'] == 'success')} ok, "
        f"{sum(1 for r in results if r['verdict'].startswith('fail'))} fail, "
        f"{sum(1 for r in results if r['verdict'].startswith('skip'))} skipped"
    )

    return jsonify({"status": "ok", "results": results})


@app.route("/api/health", methods=["GET"])
def health_check():
    """Health check endpoint for monitoring the coordinator itself."""
    return jsonify({
        "status": "ok",
        "version": COORDINATOR_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


@app.route("/api/status", methods=["GET"])
@require_api_key
def get_status():
    """Get coordinator status and recent activity, including version inventory."""
    db = get_db()

    # Recent reports summary
    recent = db.execute(
        """SELECT company_id, COUNT(*) as reports,
                  SUM(CASE WHEN verdict = 'success' THEN 1 ELSE 0 END) as success,
                  SUM(CASE WHEN verdict LIKE 'fail%' THEN 1 ELSE 0 END) as failed,
                  SUM(CASE WHEN verdict LIKE 'skip%' THEN 1 ELSE 0 END) as skipped,
                  MAX(reported_at) as last_report
           FROM reports
           WHERE reported_at > datetime('now', '-24 hours')
           GROUP BY company_id"""
    ).fetchall()

    # Per-company current version (latest report per company)
    inventory = db.execute(
        """SELECT r.company_id, r.monitor_version, r.monitor_channel, r.reported_at
           FROM reports r
           INNER JOIN (
               SELECT company_id, MAX(reported_at) AS latest
               FROM reports GROUP BY company_id
           ) m ON r.company_id = m.company_id AND r.reported_at = m.latest"""
    ).fetchall()
    inv_by_company = {
        row["company_id"]: {
            "version": row["monitor_version"],
            "channel": row["monitor_channel"] or "stable",
            "last_seen": row["reported_at"],
        }
        for row in inventory
    }

    companies = []
    for r in recent:
        c = dict(r)
        c["inventory"] = inv_by_company.get(r["company_id"], {})
        companies.append(c)

    # Atera cache info
    cache_row = db.execute(
        "SELECT COUNT(*) as agents, MAX(cached_at) as last_refresh FROM atera_cache"
    ).fetchone()

    # Channel pointers
    channels = {}
    for ch in VALID_CHANNELS:
        manifest = _read_manifest(ch)
        if manifest:
            channels[ch] = manifest.get("version")

    return jsonify({
        "companies": companies,
        "atera_cache": {
            "agents": cache_row["agents"],
            "last_refresh": cache_row["last_refresh"],
        },
        "channels": channels,
    })


# --- Releases ---

def _manifest_path(channel):
    return RELEASES_DIR / f"latest-{channel}.json"


def _read_manifest(channel):
    p = _manifest_path(channel)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception as e:
        log.error(f"Failed to read manifest for channel {channel}: {e}")
        return None


@app.route("/api/latest", methods=["GET"])
@require_api_key
def get_latest():
    """Return the manifest for a channel. Empty object if no release published."""
    channel = request.args.get("channel", "stable")
    if channel not in VALID_CHANNELS:
        return jsonify({"error": f"invalid channel; valid: {VALID_CHANNELS}"}), 400
    manifest = _read_manifest(channel)
    if not manifest:
        return jsonify({})  # No release on this channel yet
    return jsonify(manifest)


@app.route("/api/download/<path:filename>", methods=["GET"])
@require_api_key
def download_release(filename):
    """Stream a release zip from /releases. Filename is constrained to BackupCheck-v*.zip."""
    if not re.fullmatch(r"BackupCheck-v[0-9A-Za-z.\-]+\.zip", filename):
        abort(400)
    if not (RELEASES_DIR / filename).exists():
        abort(404)
    return send_from_directory(RELEASES_DIR, filename, as_attachment=True)


@app.route("/api/admin/publish", methods=["POST"])
@require_admin_key
def publish_release():
    """Publish a new release. Multipart upload of the zip; form fields version + channel."""
    version = request.form.get("version", "").strip()
    channel = request.form.get("channel", "stable").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?", version):
        return jsonify({"error": "invalid version (use semver)"}), 400
    if channel not in VALID_CHANNELS:
        return jsonify({"error": f"invalid channel; valid: {VALID_CHANNELS}"}), 400
    if "file" not in request.files:
        return jsonify({"error": "missing file upload"}), 400

    RELEASES_DIR.mkdir(parents=True, exist_ok=True)
    zip_name = f"BackupCheck-v{version}.zip"
    zip_path = RELEASES_DIR / zip_name
    request.files["file"].save(zip_path)

    # Compute SHA256 of the file(s) verified by the self-updater
    files_meta = {}
    try:
        with zipfile.ZipFile(zip_path) as zf:
            for name in ("Monitor-Backups.ps1",):
                match = next((n for n in zf.namelist() if n.endswith(name)), None)
                if not match:
                    return jsonify({"error": f"{name} missing from zip"}), 400
                with zf.open(match) as fh:
                    files_meta[name] = {"sha256": hashlib.sha256(fh.read()).hexdigest()}
    except zipfile.BadZipFile:
        zip_path.unlink(missing_ok=True)
        return jsonify({"error": "uploaded file is not a valid zip"}), 400

    # External URL for download (clients fetch through reverse proxy).
    # Honor X-Forwarded-Proto so https is preserved when behind GoDoxy.
    scheme = request.headers.get("X-Forwarded-Proto", "").split(",")[0].strip() or request.scheme
    host = request.headers.get("X-Forwarded-Host", request.host)
    base = f"{scheme}://{host}"
    manifest = {
        "version": version,
        "channel": channel,
        "files": files_meta,
        "releaseUrl": f"{base}/api/download/{zip_name}",
        "publishedAt": datetime.now(timezone.utc).isoformat(),
    }
    _manifest_path(channel).write_text(json.dumps(manifest, indent=2))
    log.info(f"Published v{version} to channel {channel}")
    return jsonify({"status": "ok", "manifest": manifest})


# --- Startup ---

with app.app_context():
    init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=os.environ.get("FLASK_DEBUG", "0") == "1")
