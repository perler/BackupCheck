#!/usr/bin/env bash
# Build a BackupCheck release zip and publish it to the coordinator.
# Usage: ./release.sh <version> [channel]
#   ./release.sh 2.2.0 stable
#
# Env vars:
#   COORDINATOR_HOST       SSH host for orbit (default: root@orbit.patsplanet.com)
#   COORDINATOR_BASE_URL   HTTPS base for /api calls (default: https://backupcheck.patsplanet.com)
#   COORDINATOR_ADMIN_KEY  Admin key for /api/admin/publish (required)

set -euo pipefail

VERSION="${1:?usage: $0 <version> [channel]}"
CHANNEL="${2:-stable}"

COORDINATOR_HOST="${COORDINATOR_HOST:-root@orbit.patsplanet.com}"
COORDINATOR_BASE_URL="${COORDINATOR_BASE_URL:-https://backupcheck.patsplanet.com}"

if [[ -z "${COORDINATOR_ADMIN_KEY:-}" ]]; then
  echo "COORDINATOR_ADMIN_KEY env var required" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.\-]+)?$ ]]; then
  echo "Invalid version (expected semver): $VERSION" >&2
  exit 1
fi

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "canary" ]]; then
  echo "Invalid channel: $CHANNEL (use stable or canary)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

ZIP_NAME="BackupCheck-v${VERSION}.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/release"
mkdir -p "$STAGE"
cp Monitor-Backups.ps1 upgrade.ps1 README.md LICENSE CHANGELOG.md "$STAGE/"
cp config.example.json "$STAGE/config.example.json"
[[ -f .env.example ]] && cp .env.example "$STAGE/" || true

(cd "$STAGE" && zip -qr "$WORK/$ZIP_NAME" .)

echo "Built $WORK/$ZIP_NAME ($(du -h "$WORK/$ZIP_NAME" | cut -f1))"

# Publish to coordinator (POST multipart). Coordinator stores the zip and writes
# latest-{channel}.json with computed SHA256 hashes.
echo "Publishing to $COORDINATOR_BASE_URL ..."
RESPONSE=$(curl -fsS -X POST \
  -H "X-Admin-Key: $COORDINATOR_ADMIN_KEY" \
  -F "version=$VERSION" \
  -F "channel=$CHANNEL" \
  -F "file=@$WORK/$ZIP_NAME" \
  "$COORDINATOR_BASE_URL/api/admin/publish")

echo "$RESPONSE" | python3 -m json.tool
echo
echo "Published v$VERSION to channel $CHANNEL."
