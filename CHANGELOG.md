# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-05-01

### Added
- **Coordinator-hosted updates**: monitor self-update can now pull manifests
  and release zips from the coordinator (`/api/latest`, `/api/download/<file>`)
  using the coordinator API key, instead of GitHub. GitHub raw remains as
  fallback when no coordinator is configured.
- **Release channels**: `latest-{channel}.json` schema with `stable` and
  `canary` channels. Clients declare their channel via `config.channel`
  (default `stable`).
- **Admin publish endpoint** (`/api/admin/publish`): coordinator accepts
  multipart uploads, computes SHA256 of release files, and writes per-channel
  manifests. Gated by `COORDINATOR_ADMIN_KEY`.
- **Version inventory** in `/api/status`: per-company current monitor version,
  channel, and last-seen timestamp. Channel pointers also surfaced.
- **`release.sh`**: workstation-side release script. Builds zip, posts to
  `/api/admin/publish`. Replaces GitHub Actions for distribution.

### Changed
- Monitor reports `version` and `channel` in every `/api/report`.
- Coordinator stores `monitor_channel` per report (with one-shot ALTER TABLE
  migration on existing DBs).
- Default update source: coordinator if configured, else legacy GitHub raw.
- **Install path is now workstation-driven** (`install-client.sh`). The old
  interactive PowerShell installer (`Install-BackupMonitor.ps1`) has been
  removed.

### Removed
- `Install-BackupMonitor.ps1` — replaced by `install-client.sh`. Installs are
  fully non-interactive: credentials sourced from IT Portal (`automat` user,
  NAS account), workstation `.env` (HC keys, coordinator URL/key). Fails
  loudly if `AD\automat` is missing in IT Portal for the target client.

## [2.1.0] - 2026-02-19

### Added
- **Coordinator API** (`coordinator/`)
  - Flask app receiving backup scan results via `POST /api/report`
  - Correlates with Atera RMM agent status (cached, refreshed every 15 min)
  - Decision matrix: OK→success, Missing+Online→fail, Missing+Offline→skip ping
  - SQLite storage for reports and Atera agent cache
  - API key authentication, health check endpoint, status dashboard
  - Docker deployment with docker-compose
  - Replaces `pause-offline-checks.py` channel muting workaround
- **Coordinator integration in Monitor-Backups.ps1**
  - Scans repos first, then POSTs all results to coordinator in one request
  - Falls back to direct HC pings if coordinator is unreachable
  - Configured via `coordinatorUrl`/`coordinatorApiKey` in config or env

### Changed
- Monitor script refactored to two-phase: scan first, then report
- Version bumped to 2.1.0

## [2.0.0] - 2026-02-18

### Added
- **Self-updating mechanism** (`Monitor-Backups.ps1`)
  - Checks GitHub for new releases every 24 hours via `latest.json`
  - Downloads release zip, verifies SHA256 checksums for each file
  - Backs up current files to `.bak`, extracts new versions, re-launches
  - Graceful fallback: update failures log a warning and continue with current version
  - `-SkipUpdateCheck` flag to bypass update check (used during re-launch)
- **HC API caching** to reduce Management API calls
  - Configuration cache in `.configured-checks.json`
  - Only calls HC Management API when: slug not cached, settings differ, or cache >7 days old
  - Reduces ~480 redundant API calls/day to near zero for stable configurations
- **Structured logging** with `Write-Log` function
  - Console + `backupcheck.log` with timestamps and severity levels
  - Automatic 7-day log rotation on each run
- **Meta-monitoring**: pings `{companyId}-monitor-health` check after each run
  - Detects when the monitor itself stops running
- **Version in ping body**: `[BackupCheck v2.0.0] Last backup: 4.2h ago (3 files)`
- **Config version field**: `configVersion: 2` in config.json for future migration
- **`latest.json`** version pointer for auto-update mechanism
- **GitHub Actions release workflow** (`.github/workflows/release.yml`)
  - Builds release zip on tag push
  - Computes SHA256 checksums
  - Updates `latest.json` in master branch
  - Creates GitHub Release with zip artifact
- **Public repo preparation**
  - MIT License
  - Public-facing README.md
  - Sanitized all client-specific references from examples

### Changed
- Version bumped from 0.5.0 to 2.0.0 (major architecture upgrade)
- `Send-HealthCheck` now accepts and uses `ConfigCache` parameter
- Installer now writes `configVersion: 2` to config.json
- `.env.example` updated with coordinator fields (for v2.1)

## [0.7.0] - 2026-02-18

### Changed
- **Switched from HC pause to channel muting** (`pause-offline-checks.py`)
  - HC's "pause" gets undone by any ping - the backup monitor's hourly failure
    pings were un-pausing checks and triggering alerts every hour
  - Now removes notification channels (`channels: ""`) from offline machines' checks
  - Failure pings still come in but no alert emails are sent
  - Channels restored (`channels: "*"`) when Atera shows agent back online
  - Muted state tracked in persistent JSON file (`/cron/data/.muted-checks.json`)
  - This is a temporary workaround - long-term fix is integrating Atera checks
    into Monitor-Backups.ps1 directly (requires auto-update mechanism)

### Changed
- Cron schedule changed from every 6 hours to **every hour at :45**
- Deployed to orbit-cron container (moved from ai.patsplanet.com cron)
- orbit-cron container migrated from `alpine:latest` to `python:3.12-slim`
  with entrypoint.sh / packages.txt pattern for easy package management

## [0.6.0] - 2026-02-17

### Added
- **Auto-pause healthchecks for offline machines** (`pause-offline-checks.py`)
  - Detects offline workstations/notebooks via Atera RMM agent status
  - Two-path decision tree: preventive muting vs already-down handling
  - Dynamic threshold: derived from each check's own period minus 1 day
  - Dual-signal safety for preventive path: Atera offline AND no recent backup ping
  - Already-down path: requires agent offline >24h (protects against Atera blips)
  - Servers excluded: only `wks` and `nb` device types are eligible
  - `--dry-run` and `--verbose` flags for safe testing

## [0.5.0] - 2026-02-11

### Added
- **Auto-configure checks based on device naming convention**
  - WKS* devices: tag `wks`, period 4 days, grace 6 hours
  - NB* devices: tag `nb`, period 8 days, grace 6 hours
  - SRV* devices: tag `srv`, period 1 day, grace 18 hours
  - Settings applied automatically via Management API on each ping

## [0.4.2] - 2026-02-11

### Fixed
- **Critical:** Installer showed "created successfully!" even when scheduled task creation failed
  - `Register-ScheduledTask` threw non-terminating error that bypassed try/catch
  - Added `-ErrorAction Stop` to properly catch errors
  - Added verification that task actually exists after creation
  - Improved error message with common causes and troubleshooting hints

## [0.4.1] - 2026-02-06

### Fixed
- **Critical:** Script crash when no existing network connection exists
  - `net use /delete` throws exception when no connection to delete
  - Combined with `$ErrorActionPreference = "Stop"`, caused silent script failure
  - Wrapped disconnect command in nested try-catch to ignore "not found" errors
- Added outer try-catch block for better error reporting

## [0.4.0] - 2026-02-05

### Fixed
- **Critical:** Repository credentials now stored in .env file instead of Windows Credential Manager
  - Previous approach only stored credentials for installer user, not scheduled task user
  - Monitor script now uses `net use` with stored credentials to connect to shares
- Automatic cleanup of mounted shares after script completes

### Changed
- Credential storage moved from Windows Credential Manager to .env file
- Added `REPO_USERNAME` and `REPO_PASSWORD` fields to .env file
- Monitor script now explicitly connects to shares before scanning

## [0.3.9] - 2026-02-04

### Fixed
- Tags now work correctly using Management API v1 (ping endpoint doesn't support tags)
- Added `tags` field to installer config.json output
- Monitor script now loads HC_API_KEY for tag management

## [0.3.8] - 2026-02-04

### Fixed
- Show detailed error messages when repository access validation fails

## [0.3.7] - 2026-02-04

### Fixed
- Added missing `Get-EnvFile` function to installer (was causing error on existing .env)
- Synced version numbers across all scripts

## [0.3.6] - 2026-02-04

### Added
- Detection of corrupted backup files (`.mrimg.error_loading`)
- Check fails when error files are present (triggers cleanup notification)

### Fixed
- Exclude `.error_loading` and `.tmp` files from backup count
- Prevent false positives from Macrium temporary/error files

## [0.3.5] - 2026-02-04

### Changed
- Connection test always runs (even with existing .env keys)

## [0.3.4] - 2026-02-04

### Changed
- Installer detects and uses existing .env file (skips key prompts if present)
- Installer detects existing config.json and uses values as defaults

## [0.3.3] - 2026-02-04

### Changed
- Installer now asks for both Ping Key and API Key
- Test-connection check is automatically deleted after connection test
- Both keys stored in .env file

## [0.3.2] - 2026-02-04

### Changed
- Default scheduled task user changed to `AD\automat`

## [0.3.1] - 2026-02-04

### Fixed
- Force TLS 1.2 for HTTPS connections (fixes connection issues on older Windows)
- Improved error messages during ping key validation

## [0.3.0] - 2026-02-04

### Added
- Tag support for healthchecks.io checks
  - Automatic tags: "backup", "macrium", and companyId (lowercase)
  - Custom tags via `tags` array in config.json

## [0.2.0] - 2026-02-03

### Changed
- Installer now prompts for TWO separate credentials:
  - Repository credentials (for NAS/share access) - stored in .env file (changed in v0.4.0)
  - Scheduled task credentials (for running the task) - default username "automat", see IT-Portal
- Domain name for repository credentials is auto-extracted from share path (e.g., \\nas002\share → nas002)
- Updated version to 0.2.0

## [0.1.0] - 2026-02-03

### Added
- Initial release
- Monitor-Backups.ps1 - Main monitoring script that checks for recent .mrimg files
- Install-BackupMonitor.ps1 - Interactive installer with scheduled task setup
- Auto-detection of Macrium Reflect repositories via mrserver.exe
- healthchecks.io integration with auto-provisioning support
- Skip machines with backup_running file present
- Configurable backup age threshold (default 24 hours)
- Windows Scheduled Task creation (hourly execution)
- Credential validation during installation
