#!/usr/bin/env bash
# Install BackupCheck on a Windows server, fully driven from this workstation.
#
# Usage: ./install-client.sh <CLIENT-CODE> <TARGET-HOST> [--ssh-user USER] [--task-user USER] [--dry-run]
#   ./install-client.sh PR 192.168.101.12
#
# Reads from BackupCheck/.env: HC_PING_KEY, HC_API_KEY, COORDINATOR_URL, COORDINATOR_API_KEY
# Looks up via IT Portal:
#   - AD\automat password (object Account, type AD, username automat) — fails if missing.
#   - NAS share user/password (backup or backupadmin on the client's NAS device).
#
# Detects Macrium repos via mrserver.exe over SSH, writes config + .env on target,
# downloads release zip from coordinator, registers BackupMonitor scheduled task.

set -euo pipefail

CLIENT_CODE="${1:-}"
TARGET_HOST="${2:-}"
SSH_USER="admin"
DRY_RUN=0
TASK_USER_ARG=""

while [[ $# -gt 2 ]]; do
  case "$3" in
    --ssh-user)   SSH_USER="$4"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --task-user)  TASK_USER_ARG="$4"; shift 2 ;;
    *)            echo "Unknown flag: $3" >&2; exit 2 ;;
  esac
done

if [[ -z "$CLIENT_CODE" || -z "$TARGET_HOST" ]]; then
  cat >&2 <<EOF
Usage: $0 <CLIENT-CODE> <TARGET-HOST> [--ssh-user USER] [--task-user USER] [--dry-run]
Example: $0 PR 192.168.101.12
EOF
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
ITPORTAL_DIR="/home/work/tools/itportal"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
fail()  { red "ERROR: $*"; exit 1; }

# --- 1. Load workstation .env ---
# The IT Portal lookups below run through tools/itportal, which reads ITPORTAL_API_KEY from
# the environment. That key lives in the workstation-wide ~/.env, not in this repo's .env, so
# without it the lookups fail with a bare 401 "Invalid API Key". Source it FIRST so the repo's
# own .env still wins for anything both files define.
if [[ -z "${ITPORTAL_API_KEY:-}" && -f "$HOME/.env" ]]; then
  set -a; source "$HOME/.env"; set +a
fi
[[ -f "$REPO_ROOT/.env" ]] || fail "$REPO_ROOT/.env missing"
set -a; source "$REPO_ROOT/.env"; set +a
: "${HC_PING_KEY:?missing in .env}"
: "${HC_API_KEY:?missing in .env}"
: "${COORDINATOR_URL:?missing in .env}"
: "${COORDINATOR_API_KEY:?missing in .env}"
: "${ITPORTAL_API_KEY:?not in the environment and not in ~/.env — IT Portal lookups would 401}"

# --- 2. SSH connectivity + auto-discover AD domain / workgroup status from target ---
cyan "Client: $CLIENT_CODE  Target: $SSH_USER@$TARGET_HOST"
# PowerShell over SSH is finicky with embedded quotes — keep the remote command simple.
# Each value is emitted as KEY=value and parsed BY KEY, never by line number: this probe
# used to merge stderr into stdout and read lines 1/2/3, so on the first connection to a
# host the "Warning: Permanently added ... to the list of known hosts." banner became
# line 1 and shifted every value by one. A domain-joined server then read PartOfDomain as
# the *domain name*, which is not "True", and was silently treated as a workgroup host.
# stderr is therefore left on the terminal (where real errors belong) rather than captured.
PROBE_RAW=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$TARGET_HOST" \
  'powershell -NoProfile -Command "$cs = Get-CimInstance Win32_ComputerSystem; Write-Output (\"HOSTNAME=\" + $env:COMPUTERNAME); Write-Output (\"DOMAIN=\" + $cs.Domain); Write-Output (\"PARTOFDOMAIN=\" + $cs.PartOfDomain)"' \
  | tr -d '\r') \
  || fail "Cannot reach $SSH_USER@$TARGET_HOST over SSH"

probe_val() { printf '%s\n' "$PROBE_RAW" | sed -n "s/^$1=//p" | tail -1; }
TARGET_HOSTNAME=$(probe_val HOSTNAME)
AD_DOMAIN=$(probe_val DOMAIN)
PART_OF_DOMAIN=$(probe_val PARTOFDOMAIN)

[[ -n "$TARGET_HOSTNAME" ]] || fail "Probe returned no HOSTNAME from $TARGET_HOST — got: $(printf '%s' "$PROBE_RAW" | head -3 | tr '\n' '|')"
# Fail closed: never guess the account model from an unrecognised value.
case "$PART_OF_DOMAIN" in
  True|False) ;;
  *) fail "Could not determine domain membership of $TARGET_HOST (PARTOFDOMAIN='$PART_OF_DOMAIN'). Refusing to guess between an AD and a local task account." ;;
esac

if [[ "$PART_OF_DOMAIN" == "True" ]]; then
  [[ -n "$AD_DOMAIN" && "$AD_DOMAIN" != "$TARGET_HOSTNAME" ]] || fail "Could not auto-detect AD domain from $TARGET_HOST (USERDNSDOMAIN empty — is this server domain-joined?)"
  AD_DOMAIN=$(echo "$AD_DOMAIN" | tr 'A-Z' 'a-z')
  # AD short name = first label (ad.pro-return.de → ad)
  AD_SHORT=$(echo "$AD_DOMAIN" | cut -d. -f1)
  green "  SSH OK ($TARGET_HOSTNAME, AD: $AD_DOMAIN)"
else
  green "  SSH OK ($TARGET_HOSTNAME, WORKGROUP — local task account)"
fi

# --- 4a. Task account credential lookup ---
if [[ "$PART_OF_DOMAIN" == "True" ]]; then
# AD\automat password lookup
# IT Portal has a first-class "Object Account" concept (type "AD Accounts") that is
# *separate* from AdditionalCredentials. The automat user is one of these. To fetch:
#   1. /Companies/?abbreviation=<CODE>  → resolve company.id
#   2. /Accounts/?name=automat          → filter results by company.id
#   3. /Accounts/<id>/credentials       → {username, password}
# Listing /Accounts/ returns username/password as the placeholder string "True" — the
# real credential body is only on the /credentials sub-endpoint.
cyan "Looking up AD\\automat password in IT Portal..."
AUTOMAT_PASS=$(cd "$ITPORTAL_DIR" && node -e "
const config = require('./config').load();
const axios = require('axios');
const code = '$CLIENT_CODE';
const http = axios.create({ baseURL: config.baseURL, headers: { Authorization: config.apiKey } });
(async () => {
  const cR = await http.get('/Companies/', { params: { abbreviation: code } });
  const c = cR.data.data.results[0];
  if (!c) { console.error('NOT_FOUND'); process.exit(3); }
  const aR = await http.get('/Accounts/', { params: { name: 'automat' } });
  const matches = aR.data.data.results.filter(a =>
    a.company.id === c.id &&
    (a.type.name || '').toLowerCase() === 'ad accounts' &&
    (a.name || '').toLowerCase() === 'automat'
  );
  if (matches.length === 0) { console.error('NOT_FOUND'); process.exit(3); }
  if (matches.length > 1) { console.error('AMBIGUOUS:' + matches.map(m=>m.id).join(',')); process.exit(4); }
  const credR = await http.get('/Accounts/' + matches[0].id + '/credentials');
  const pw = credR.data.password || credR.data.data?.password;
  if (!pw) { console.error('NO_PASSWORD'); process.exit(5); }
  process.stdout.write(pw);
})().catch(e => { console.error('ERR:' + (e.response?.data ? JSON.stringify(e.response.data) : e.message)); process.exit(5); });
" 2>&1) || {
  case "$AUTOMAT_PASS" in
    NOT_FOUND)
      cat <<EOF >&2

$(red "FAILURE: AD\\automat not found in IT Portal for $CLIENT_CODE")

This installer requires an AD account 'automat' on the client's domain
($AD_DOMAIN) and a corresponding IT Portal entry.

To fix:
  1. Create user 'automat' in Active Directory on $AD_DOMAIN
     (Domain User; password should never expire; no interactive logon needed,
      but it must be a Domain User and have rights to "Log on as a batch job").
  2. In IT Portal, create an Object Account named e.g. 'automat@$AD_DOMAIN'.
     Add an Additional Credential of type 'AD' with username 'automat' and the
     password you set in step 1. The Account's name must contain '$AD_DOMAIN'
     so this installer can match it.
  3. Re-run this command.

This is essential infrastructure — do not paper over it with a one-off password.
EOF
      exit 1 ;;
    AMBIGUOUS:*)
      red "FAILURE: Multiple AD/automat entries match $AD_DOMAIN: ${AUTOMAT_PASS#AMBIGUOUS:}"
      exit 1 ;;
    *)
      red "Lookup failed: $AUTOMAT_PASS"; exit 1 ;;
  esac
}
green "  AD\\automat password retrieved"
TASK_USER="$AD_SHORT\\automat"
TASK_PASS="$AUTOMAT_PASS"
else
# Local task account lookup (workgroup mode) — this host has no Active Directory, so the
# scheduled task must run as a LOCAL account. Mirrors the NAS credential lookup pattern
# below: resolve the client's company, find the Device matching this hostname, then pick
# an AdditionalCredential attached to that Device.
cyan "Looking up local task account credentials in IT Portal for $TARGET_HOSTNAME..."
TASK_CREDS_JSON=$(cd "$ITPORTAL_DIR" && TARGET_HOSTNAME="$TARGET_HOSTNAME" CLIENT_CODE="$CLIENT_CODE" TASK_USER_ARG="$TASK_USER_ARG" node -e "
const config = require('./config').load();
const axios = require('axios');
const code = process.env.CLIENT_CODE;
const hostname = process.env.TARGET_HOSTNAME.toLowerCase();
const taskUserArg = process.env.TASK_USER_ARG;
const http = axios.create({ baseURL: config.baseURL, headers: { Authorization: config.apiKey } });
(async () => {
  const cR = await http.get('/Companies/', { params: { abbreviation: code } });
  const company = cR.data.data.results[0];
  if (!company) { console.error('NOT_FOUND'); process.exit(3); }
  const AC = require('./itportal-additional-creds');
  const ac = new AC();
  const all = await ac._fetchAll();
  const myDevices = new Map();
  let cursor = null;
  do {
    const dR = await http.get('/Devices/', { params: { companyId: company.id, limit: 100, ...(cursor ? { cursor } : {}) } });
    for (const d of dR.data.data.results) myDevices.set(d.id, d.name);
    cursor = dR.data.data.nextCursor;
  } while (cursor && myDevices.size < 1000);
  const matchingDeviceIds = [...myDevices.entries()]
    .filter(([id, name]) => (name || '').toLowerCase() === hostname || (name || '').toLowerCase().startsWith(hostname + '.'))
    .map(([id]) => id);
  if (matchingDeviceIds.length === 0) { console.error('NO_DEVICE:' + hostname); process.exit(3); }
  const creds = all.filter(c =>
    c.portalObject.itemType === 'Device' &&
    matchingDeviceIds.includes(c.portalObject.id)
  );
  let pick;
  if (taskUserArg) {
    pick = creds.find(c => (c.username || '').toLowerCase() === taskUserArg.toLowerCase());
    if (!pick) { console.error('NO_MATCH:' + taskUserArg); process.exit(3); }
  } else {
    pick = creds.find(c => (c.username || '').toLowerCase() === 'automat');
    if (!pick) {
      console.error(creds.length ? 'NO_AUTOMAT:' + creds.map(c => c.username).join(',') : 'NO_CREDS');
      process.exit(3);
    }
  }
  process.stdout.write(JSON.stringify({ user: pick.username, pass: pick.password }));
})().catch(e => { console.error('ERR:' + (e.response?.data ? JSON.stringify(e.response.data) : e.message)); process.exit(5); });
" 2>&1) || {
  case "$TASK_CREDS_JSON" in
    NOT_FOUND)
      fail "Client $CLIENT_CODE not found in IT Portal." ;;
    NO_DEVICE:*)
      cat <<EOF >&2

$(red "FAILURE: No IT Portal Device named '$TARGET_HOSTNAME' found for $CLIENT_CODE")

This is a workgroup host (no Active Directory at this site), so the scheduled
task needs a LOCAL account on $TARGET_HOSTNAME plus a matching IT Portal
Device entry to look up its password:
  1. Create a Device in IT Portal for $CLIENT_CODE named '$TARGET_HOSTNAME'.
  2. Add an Additional Credential on that Device with the local account's
     username and password (e.g. 'automat').
  3. Re-run this command.
EOF
      exit 1 ;;
    NO_MATCH:*)
      fail "No credential with username '${TASK_CREDS_JSON#NO_MATCH:}' found on Device '$TARGET_HOSTNAME' in IT Portal." ;;
    NO_CREDS)
      cat <<EOF >&2

$(red "FAILURE: No credentials recorded on Device '$TARGET_HOSTNAME' in IT Portal")

This is a workgroup host, so the scheduled task must run as a LOCAL account on
$TARGET_HOSTNAME (there is no Active Directory at this site), and its password
has to come from IT Portal.

To fix:
  1. Create a local account on $TARGET_HOSTNAME (member of the local
     Administrators group; rights to "Log on as a batch job").
  2. Add an Additional Credential on the '$TARGET_HOSTNAME' Device in IT Portal
     with that account's username and password. Name it 'automat' to have it
     picked up automatically.
  3. Re-run this command (add --task-user <username> if you named it otherwise).
EOF
      exit 1 ;;
    NO_AUTOMAT:*)
      cat <<EOF >&2

$(red "FAILURE: No 'automat' credential found on Device '$TARGET_HOSTNAME'")

This is a workgroup host, so the task account must be a LOCAL account on
$TARGET_HOSTNAME (there is no Active Directory at this site). IT Portal has
credential(s) on this Device (${TASK_CREDS_JSON#NO_AUTOMAT:}) but none is
named 'automat', and this installer will not guess which one to use.

To fix:
  1. Create a local account on $TARGET_HOSTNAME (member of the local
     Administrators group; rights to "Log on as a batch job").
  2. Ensure IT Portal has an Additional Credential on the '$TARGET_HOSTNAME'
     Device with that account's username and password.
  3. Re-run with --task-user <username> to select it explicitly.
EOF
      exit 1 ;;
    *)
      fail "Task account lookup failed: $TASK_CREDS_JSON" ;;
  esac
}
TASK_USER_NAME=$(echo "$TASK_CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['user'])")
TASK_USER_PASS=$(echo "$TASK_CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['pass'])")
green "  Local task account credentials retrieved: $TASK_USER_NAME"
# Register-ScheduledTask -User will NOT accept the ".\user" form — it fails with
# 0x80070534 "No mapping between account names and security IDs was done". Qualify the
# local account with the machine name instead (machine names are never localised).
TASK_USER="$TARGET_HOSTNAME\\$TASK_USER_NAME"
TASK_PASS="$TASK_USER_PASS"
fi

# --- 4b. Detect Macrium repos (needed before NAS lookup so we know which NAS to authenticate) ---
cyan "Detecting Macrium repositories on $TARGET_HOST..."
REPOS_CSV=$(ssh "$SSH_USER@$TARGET_HOST" 'powershell -NoProfile -Command "& \"C:\Program Files\Macrium\SiteManager\mrserver.exe\" --action get-repo-status --outputtoconsole 2>$null"' || true)
REPOS_RAW=$(printf '%s' "$REPOS_CSV" | python3 -c "
import sys, csv, io
text = sys.stdin.read().replace('\r', '')
reader = csv.reader(io.StringIO(text))
rows = list(reader)
header = rows[0] if rows else []
try:
    idx = header.index('Repository Path')
except ValueError:
    sys.exit(0)
for r in rows[1:]:
    if len(r) > idx and r[idx]:
        print(r[idx])
")
REPOS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && REPOS+=("$line")
done <<< "$REPOS_RAW"
[[ ${#REPOS[@]} -gt 0 ]] || fail "No Macrium repositories detected. Is Macrium Site Manager installed and configured?"

NAS_SERVERS=$(printf '%s\n' "${REPOS[@]}" | sed -E 's@^\\\\([^\\]+)\\.*@\1@' | sort -u)
NAS_SERVER_COUNT=$(echo "$NAS_SERVERS" | wc -l)
[[ "$NAS_SERVER_COUNT" -eq 1 ]] || fail "Repositories span multiple NAS servers — this installer expects one: $NAS_SERVERS"
NAS_HOSTNAME=$(echo "$NAS_SERVERS" | head -1)
green "  Found ${#REPOS[@]} repository(ies) on \\\\${NAS_HOSTNAME}:"
for r in "${REPOS[@]}"; do echo "    - $r"; done

# --- 4c. NAS credential lookup ---
# Resolve via the IT Portal REST API directly (same pattern as automat above):
#   /Companies/?abbreviation=<CODE>           → company.id
#   /Devices/?company=<id>                    → list this client's devices
#   /AdditionalCredentials/?portalObject_id=<deviceId>&portalObject_itemType=Device
#                                              → creds attached to each device
# Find the device that has a backup/backupadmin user and use its credential.
# The skill's `info <code>` shortcut is buggy (lowercase falls through to fuzzy
# matches) — never use it for credential resolution.
cyan "Looking up NAS credentials in IT Portal for \\\\${NAS_HOSTNAME}..."
NAS_CREDS_JSON=$(cd "$ITPORTAL_DIR" && NAS_HOSTNAME="$NAS_HOSTNAME" CLIENT_CODE="$CLIENT_CODE" node -e "
const config = require('./config').load();
const axios = require('axios');
const code = process.env.CLIENT_CODE;
const nasHost = process.env.NAS_HOSTNAME.toLowerCase();
const http = axios.create({ baseURL: config.baseURL, headers: { Authorization: config.apiKey } });
(async () => {
  const cR = await http.get('/Companies/', { params: { abbreviation: code } });
  const company = cR.data.data.results[0];
  if (!company) { console.error('NOT_FOUND'); process.exit(3); }
  const AC = require('./itportal-additional-creds');
  const ac = new AC();
  const all = await ac._fetchAll();
  // Get this company's devices and find the one matching the actual NAS hostname
  // (case-insensitive name match on the value mrserver.exe returned in the UNC path).
  const myDevices = new Map();
  let cursor = null;
  do {
    const dR = await http.get('/Devices/', { params: { companyId: company.id, limit: 100, ...(cursor ? { cursor } : {}) } });
    for (const d of dR.data.data.results) myDevices.set(d.id, d.name);
    cursor = dR.data.data.nextCursor;
  } while (cursor && myDevices.size < 1000);
  const matchingDeviceIds = [...myDevices.entries()]
    .filter(([id, name]) => (name || '').toLowerCase() === nasHost || (name || '').toLowerCase().startsWith(nasHost + '.'))
    .map(([id]) => id);
  if (matchingDeviceIds.length === 0) {
    console.error('NO_DEVICE:' + nasHost);
    process.exit(3);
  }
  const mine = all.filter(c =>
    c.portalObject.itemType === 'Device' &&
    matchingDeviceIds.includes(c.portalObject.id) &&
    ['backup', 'backupadmin'].includes((c.username || '').toLowerCase())
  );
  if (mine.length === 0) { console.error('NO_CREDS_ON:' + nasHost); process.exit(3); }
  // Prefer backupadmin
  const pref = mine.find(c => (c.username || '').toLowerCase() === 'backupadmin') || mine[0];
  process.stdout.write(JSON.stringify({
    user: pref.username, pass: pref.password,
    device: myDevices.get(pref.portalObject.id) || pref.portalObject.itemName
  }));
})().catch(e => { console.error('ERR:' + (e.response?.data ? JSON.stringify(e.response.data) : e.message)); process.exit(5); });
" 2>&1) || {
  if [[ "$NAS_CREDS_JSON" == "NOT_FOUND" ]]; then
    fail "No NAS user 'backup' or 'backupadmin' found for $CLIENT_CODE in IT Portal."
  fi
  fail "NAS lookup failed: $NAS_CREDS_JSON"
}
NAS_USER=$(echo "$NAS_CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['user'])")
NAS_PASS=$(echo "$NAS_CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['pass'])")
NAS_DEVICE=$(echo "$NAS_CREDS_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['device'])")
green "  NAS credentials: $NAS_DEVICE\\$NAS_USER"

if [[ $DRY_RUN -eq 1 ]]; then
  cyan "[dry-run] Would now write config + .env, install task. Stopping."
  exit 0
fi

# --- 6. Generate config + .env ---
TMPDIR=$(mktemp -d)
STAGING_CREATED=0
# The staged install-args.json holds the task account's PLAINTEXT password. If the remote
# install fails part-way (it runs with $ErrorActionPreference="Stop"), the tidy-up further
# down never executes and that file is left sitting on the client's disk — so clean it from
# a trap instead of inline.
cleanup() {
  rm -rf "$TMPDIR"
  if [[ "$STAGING_CREATED" == "1" ]]; then
    ssh "$SSH_USER@$TARGET_HOST" 'powershell -NoProfile -Command "Remove-Item C:\BackupCheck-staging -Recurse -Force -EA SilentlyContinue"' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
python3 - "$TMPDIR/config.json" "$CLIENT_CODE" "${REPOS[@]}" <<'PYEOF'
import json, sys
out, code = sys.argv[1], sys.argv[2]
repos = sys.argv[3:]
config = {
  "configVersion": 2,
  "companyId": code,
  "repositories": repos,
  "backupMaxAgeHours": 24,
  "backupFilePattern": "*.mrimg",
  "skipIfRunning": True,
  "runningFilePattern": "backup_running*",
  "healthchecksBaseUrl": "https://hc-ping.com",
  "autoDetectRepositories": False,
  "tags": [],
  "channel": "stable"
}
with open(out, "w") as f: json.dump(config, f, indent=2)
PYEOF

cat > "$TMPDIR/.env" <<EOF
HC_PING_KEY=$HC_PING_KEY
HC_API_KEY=$HC_API_KEY
REPO_USERNAME=$NAS_DEVICE\\$NAS_USER
REPO_PASSWORD=$NAS_PASS
COORDINATOR_URL=$COORDINATOR_URL
COORDINATOR_API_KEY=$COORDINATOR_API_KEY
EOF

# --- 7. Push setup script + run it on target ---
cyan "Setting up C:\\BackupCheck on $TARGET_HOST..."
COORD_BASE="${COORDINATOR_URL%/api/report}"
LATEST_URL="$COORD_BASE/api/latest?channel=stable"

LATEST_JSON=$(curl -fsS -H "X-API-Key: $COORDINATOR_API_KEY" "$LATEST_URL")
ZIP_NAME=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['releaseUrl'].rsplit('/',1)[1])")
VERSION=$(echo "$LATEST_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")
green "  Coordinator latest: v$VERSION ($ZIP_NAME)"

# Stage all secrets in a JSON file the remote PS script reads, then deletes.
# This avoids passing passwords containing !/#/% through cmd.exe arg parsing.
python3 - "$TMPDIR/install-args.json" <<PYEOF
import json, sys
json.dump({
    "ZipUrl": "$COORD_BASE/api/download/$ZIP_NAME",
    "CoordApiKey": "$COORDINATOR_API_KEY",
    "TaskUser": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$TASK_USER"),
    "TaskPassword": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$TASK_PASS"),
}, open(sys.argv[1], "w"))
PYEOF

# Push config, env, and install args; then run the remote install script (also pushed).
cat > "$TMPDIR/run-install.ps1" <<'REMOTEEOF'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$installDir = "C:\BackupCheck"
$staging = "C:\BackupCheck-staging"
$args = Get-Content (Join-Path $staging "install-args.json") -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# Download release zip
$zipPath = Join-Path $installDir "release.zip"
Invoke-WebRequest -Uri $args.ZipUrl -Headers @{ "X-API-Key" = $args.CoordApiKey } -OutFile $zipPath -UseBasicParsing
Expand-Archive -Path $zipPath -DestinationPath $installDir -Force
Remove-Item $zipPath -Force

# Move config + .env into place
Move-Item -Force (Join-Path $staging "config.json") (Join-Path $installDir "config.json")
Move-Item -Force (Join-Path $staging ".env")        (Join-Path $installDir ".env")

# Register/replace scheduled task
$taskName = "BackupMonitor"
$scriptPath = Join-Path $installDir "Monitor-Backups.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -WorkingDirectory $installDir
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RunOnlyIfNetworkAvailable

Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $args.TaskUser -Password $args.TaskPassword `
    -Description "BackupCheck hourly Macrium repository scan" `
    -RunLevel Highest | Out-Null

Write-Host "Scheduled task BackupMonitor registered as $($args.TaskUser)" -ForegroundColor Green

# (Staging directory is wiped by the caller after this script returns)

# Trigger an immediate run for verification
Start-ScheduledTask -TaskName $taskName
Write-Host "Triggered first run." -ForegroundColor Green
REMOTEEOF

# Stage files in C:\BackupCheck-staging\ (a fixed, predictable path that doesn't depend on
# the actual SSH user's profile directory — admin.AD vs admin etc.)
ssh "$SSH_USER@$TARGET_HOST" 'powershell -NoProfile -Command "New-Item -ItemType Directory -Path C:\BackupCheck-staging -Force | Out-Null"' >/dev/null
STAGING_CREATED=1
scp -q "$TMPDIR/config.json" "$TMPDIR/.env" "$TMPDIR/install-args.json" "$TMPDIR/run-install.ps1" \
    "$SSH_USER@$TARGET_HOST:C:/BackupCheck-staging/"

ssh "$SSH_USER@$TARGET_HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File C:/BackupCheck-staging/run-install.ps1"
# staging (incl. the plaintext password) is removed by the EXIT trap, success or failure

# --- 8. Wait briefly + verify on coordinator ---
green "  Install complete. Waiting 15s for first run to report..."
sleep 15
cyan "Coordinator status for $CLIENT_CODE:"
curl -fsS -H "X-API-Key: $COORDINATOR_API_KEY" "${COORDINATOR_URL%/api/report}/api/status" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '$CLIENT_CODE'.lower()
for c in data.get('companies', []):
    if c['company_id'] == target:
        inv = c.get('inventory', {})
        print(f\"  {c['company_id']}: v{inv.get('version')}/{inv.get('channel')} \"
              f\"— {c['reports']} reports, {c['success']} ok, {c['failed']} fail, {c['skipped']} skipped\")
        break
else:
    print(f'  {target}: no report yet (the first scheduled run may still be in progress)')
"

green ""
green "Done."
