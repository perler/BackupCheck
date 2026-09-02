# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.5.0] - 2026-09-02

Client `Monitor-Backups.ps1` v2.5.0. Deployed by hand to RAHR DC-001 on 2026-09-02; **not**
published to the coordinator `stable` channel yet, so no other client picks it up on its own.
Both changes come from the RAHR air-gap backup failure (Asana `✨ 🔴 RAHR USB Copy`,
1218079300179580) and the 2026-09-02 NAS001 outage.

### Added
- **Air-gap media are walked and every machine's newest image chain is asserted restorable.**
  New optional config key `airGapRepositories`: a list of medium roots (the USB Copy targets,
  e.g. `\\nas001\usbshare1`), each holding `<share-copy>\<MACHINE>\...\*.mrimg`. Per
  machine the newest chain (by last-written member) must have a `-00-00` base **and** every
  member must carry the Macrium end-of-file marker `__79241006_2651_11D4_` in its last 64
  bytes — the test that separated four complete-but-misnamed base images from three copies
  that died mid-write on RAHR's media on 2026-08-16, at one 64-byte read per file. Files not
  named as chain members (USB Copy `_Conflict` artefacts, `.tmp` fragments) are counted but
  never satisfy the assertion, because Macrium cannot see them either. A member without the
  marker written within the last hour is reported as in progress rather than failed.
  The verdict goes to a single check `{companyId}-usb-copy` (tags `backup macrium <code>
  usbcopy`, HC default period/grace) with one line per machine in the ping body; any failing
  machine fails the check — a failed assertion is that machine's air-gap copy being
  unrestorable, and is never a skip. No medium reachable → no ping, so the check goes late.
  This replaces the paused hc.io check "RAHR USB Copy" (4094d7dc-…), which was fed by a DSM
  disk-warning webhook and could not see the backup it was named after.

### Changed
- **A run that reaches none of its configured repositories now reports the monitor FAILED.**
  On 2026-09-02 RAHR's NAS001 did not come back after a site power outage; the monitor logged
  "Repository not accessible" for both shares, summarised 0 healthy / 0 failed / 0 skipped and
  still pinged `rahr-monitor-health` healthy every hour, so a dead NAS raised no alert until the
  per-machine checks expired ~42 h later. The meta ping is now `/fail`, with the reason and the
  repository list in the body, whenever `repositories` is non-empty and zero of them passed
  `Test-Path`. The success body now also carries `N of M repositories reachable`. Exit code is
  1 in that case, as it is for any failed machine or failed air-gap assertion.

## [2.4.0] - 2026-08-20

Client `Monitor-Backups.ps1` v2.4.0, published to the `stable` channel on 2026-08-20.
All seven clients were on 2.3.0/stable at publish time and pick it up on their next
update check; that check is throttled to once per 24 h, so the rollout completes within
a day rather than immediately. STPH was used as the release check — it self-updated and
ran clean on Windows PowerShell 5.1 at 16:54 CEST, reporting five machines healthy.
Also carries the installer (`install-client.sh`) and coordinator (`coordinator/app.py`,
v2.2.6) changes below; orbit was already running coordinator 2.2.6, so no redeploy was
needed despite the earlier note to the contrary.

### Changed
- **Corrupt backup files no longer fail a check on their own — corrupt *and* stale
  still does.** A `.error_loading` file stays on disk until a human deletes it, and
  the verdict was `IsFresh -and -not HasErrorFiles`, so one corrupt leftover pinned a
  check DOWN indefinitely no matter how well the machine was backing up. STPH WKS011
  mailed a DOWN alert every day from 13. to 20.08.2026 with an unbroken, current image
  chain behind it — eleven leftovers from two corruption waves in July and August that
  Macrium had already recovered from on its own (new full 10.08., clean increments
  since). Worse than the noise: the alert body read `ERROR: 6 corrupted backup file(s)
  detected`, which is indistinguishable from a backup that is actually failing, and it
  sent an operator looking for a client to notify about a backup that was fine.
  Corrupt-but-fresh is now a **warning** — the check stays UP, the ping body leads with
  `WARNING: N corrupted backup file(s) left on disk (.error_loading) - delete them`, and
  the summary counts warnings separately. Corrupt with nothing fresh is the case this
  detection exists for and still fails, for every device type: the stale-workstation
  tolerance added in v2.2.4 deliberately does not apply to it.

### Added
- **Workgroup (non-domain-joined) targets are now supported.** The installer probed
  `Win32_ComputerSystem.Domain` and demanded an AD `automat` account. On a workgroup
  host that property returns `WORKGROUP`, which is not equal to the hostname, so the
  existing guard *passed* and the run then died in the AD lookup telling the operator
  to "create user automat in Active Directory" — impossible at a site with no AD.
  It now reads `PartOfDomain` and branches: domain hosts keep the AD path untouched,
  workgroup hosts resolve a **local** task account from an IT Portal Additional
  Credential on the target host's own Device.
- `--task-user USER` selects which credential to use when it is not named `automat`.
  Without it the installer prefers `automat` and refuses to guess between others.

### Fixed
- **Corrupted files with a collision suffix were not counted.** Macrium appends a
  number when the target name is taken, producing `.error_loading1`, `.error_loading2`
  and so on, but detection filtered on `*.error_loading` and the freshness scan
  excluded only `\.(error_loading|tmp)$`. On STPH WKS011 that reported 6 corrupted
  files when 11 were on disk — and the five it missed were the *newer* wave, so the
  count understated the problem in exactly the direction that matters. Both the filter
  and the exclusion regex now match `.error_loading` followed by optional digits.
- **The coordinator created healthchecks.io checks and left them at HC's defaults.**
  It provisions checks by pinging with `?create=1` but never called the management
  API afterwards, so an auto-created check kept timeout 86400 (1 day), grace 3600
  (1 hour) and no tags. The device-type profile (wks 4d/6h, nb 8d/6h, srv 1d/18h,
  plus `backup macrium <code> <type>` tags) existed only client-side in
  `Get-DeviceTypeSettings`, on the direct-ping path that stopped running for machine
  checks when the coordinator took over pinging in v2.1. It went unnoticed because
  every pre-existing check had been configured before that hand-over; NM was the
  first client onboarded since, and `nm-wks001` came out as the only check in the
  account at 86400/3600 with no tags. Left alone, every client onboarded from here
  would get a 1-day period and 1-hour grace on workstation checks — exactly the
  false-alarm pattern v2.2.4 was released to stop, firing at the weekend on a
  workstation that legitimately goes a few days between images. The profile now
  lives in `DEVICE_PROFILES` in the coordinator and is applied through the
  management API on the first report that follows a check being created. The result
  is cached per slug in a new `hc_check_config` table, so it costs one extra API
  call per check per lifetime, not one per report. Machines whose name matches no
  known device type are left untouched.
- **Scheduled task registration failed for local accounts.** `Register-ScheduledTask`
  rejects the `.\user` form with `0x80070534` ("No mapping between account names and
  security IDs was done"). Local task accounts are now qualified as `MACHINE\user`.
- **The staged `install-args.json` — which holds the task account's plaintext
  password — was left on the client when the remote install failed.** The remote
  script runs with `$ErrorActionPreference="Stop"`, so a mid-way failure skipped the
  inline tidy-up entirely. Staging is now removed from an `EXIT` trap, success or
  failure.
- **IT Portal lookups failed with a bare `401 Invalid API Key`** unless the caller
  happened to have `ITPORTAL_API_KEY` exported already. The key lives in the
  workstation-wide `~/.env`, not in the repo's `.env`; it is now sourced when absent,
  before the repo `.env` so repo values still win.
- Clearer failure output when the target's Device has *no* credentials at all, rather
  than reporting an empty list of candidate usernames.

## [2.3.0] - 2026-08-11

### Added
- **Flat repositories can now name their own machine.** A `config.json` repository entry may
  be an object `{ "path": ..., "machine": ... }` instead of a plain string: the directory
  itself IS the machine (named by `machine`), with no subdirectory enumeration. Some Macrium
  destinations write `.mrimg` files directly into the destination folder with no per-machine
  subdirectory, so there is no directory name to take a machine name from. `Get-BackupRepositories`
  normalises every entry to `{ Path; Machine }` so nothing downstream has to ask "is this a
  string?" — Machine is `$null` for plain strings and auto-detected repositories, unchanged.
  `Test-BackupHealth` gained an optional `-MachineName` that overrides `Split-Path -Leaf` when set.
- **`install-client.sh --repo <path>[=<machine>]`** (repeatable) supplies repositories directly
  and skips `mrserver.exe` detection entirely — for standalone Macrium Reflect installs with no
  Site Manager, or to name a flat repository's machine explicitly. Emits the object form in the
  generated `config.json` for specs carrying a machine name, a plain string otherwise.

### Fixed
- **Local repository paths no longer count as an extra NAS server.** The NAS hostname was
  derived by stripping `\\server\` off every repository path; a local path like `D:\srv001`
  survived the regex unchanged and counted as a second "NAS server", aborting the installer with
  "spans multiple NAS servers" even at a single-NAS site. The derivation now considers UNC
  repositories only. With zero UNC repositories the NAS credential lookup is skipped entirely and
  no `REPO_USERNAME`/`REPO_PASSWORD` are written to the generated `.env`.
- **Local repository paths no longer produce a spurious red "Failed" line at monitor startup.**
  The share-connect loop tried (and failed) to `net use` non-UNC paths; it now skips any path
  that isn't `\\...` before attempting a connection.
- **Share-connect dedupe bug.** The loop tested the *full* repository path against a hashtable
  keyed by the `\\server` prefix, so it never matched and `net use /delete` + reconnect ran once
  per repository instead of once per server sharing that repository. It now keys the lookup the
  same way it's populated.
- **One unreachable repository no longer aborts the entire scan.** On a UNC path the account
  cannot read, `Test-Path` *raises* "Access is denied" instead of returning `$false`, and the
  script-wide `$ErrorActionPreference = "Stop"` turned that into a fatal error — the run died
  before Phase 2, so every other machine, healthy ones included, silently stopped reporting.
  The unreachable repository is now logged and skipped, as was always intended.
- **Single-repository clients could have broken on upgrade.** `return @(...)` unrolls a
  one-element array back to the bare element, so a client with exactly one configured repository
  would have received a raw hashtable instead of an array of one, and `foreach` would have
  iterated its *keys*. Harmless while repositories were bare strings; fixed with `return ,@(...)`
  before it could bite.
- **IT Portal NAS device lookup now tolerates FQDN/short-name mismatch.** A repository reached as
  `\\nas003.ad.example.de\backup` failed to match a Device recorded as plain `NAS003`. The lookup
  tries the name as given, then its first DNS label.

## [2.2.5] - 2026-07-21

### Fixed
- **Corrupt repositories no longer mask backup staleness.** `HasErrorFiles` was
  evaluated before `IsHealthy` when building the status message, so a
  `.error_loading` file short-circuited the freshness verdict: a machine that had
  stopped backing up entirely reported the *same* message as one backing up
  normally with a corrupt file present. The two states were indistinguishable
  for as long as the corruption persisted — on PR SRV003 that was 34 days
  (2026-06-13 → 07-18). Freshness is now computed independently of corruption
  and both conditions are reported together, e.g. `ERROR: 1 corrupted backup
  file(s) detected (.error_loading); No backups found within last 24 hours`.
- `BackupAge` / `LatestBackup` are now populated even when error files are
  present (previously left `$null`), so the coordinator records a real age for
  corrupt repositories instead of nothing.

### Changed
- `Test-BackupHealth` gains an `IsFresh` field (recent backup present,
  regardless of corruption). `IsHealthy` keeps its existing meaning — recent
  backup **and** no corrupt files — so the coordinator decision matrix and all
  HC verdicts are unaffected: corrupt repositories still fail hard.

## [2.2.4] - 2026-07-03

### Fixed
- **No more explicit `/fail` flood for stale (but not corrupt) workstation and
  notebook backups.** When a machine is online and its newest image is older
  than `backupMaxAgeHours` (24h) but the repository is intact, the monitor no
  longer pings the healthchecks.io failure endpoint. An explicit failure signal
  flips the HC check DOWN immediately and defeats the check's own Period
  tolerance (wks 4d / nb 8d + grace), so laptops and workstations that
  legitimately go days between images were generating nightly waves of false
  "DOWN | ... — No backups found within last 24 hours" alerts across every
  client. These devices are now **skipped** (no ping sent); if backups genuinely
  stop, the HC Period+grace still raises the alarm within the intended window.
- **Servers (`srv*`) keep the explicit failure ping** — they are expected to
  back up daily and are latency-critical, so fast detection is preserved.
- Corrupt-backup detection (`.error_loading`) is unchanged and still fails hard.

## [2.2.1] - 2026-05-05

### Fixed
- **Coordinator URL-encodes slugs when pinging healthchecks.io.** Machine names
  containing spaces or other URL-unsafe characters previously caused a hard
  error and silent missed pings (e.g. `stph-storage analyzer`).

### Changed
- **Coordinator pauses HC checks on `skipped_offline`.** When a notebook/
  workstation's Atera agent is offline and no recent backup exists, the
  coordinator now calls the HC management API to pause the check so the
  dashboard reflects reality instead of stale "down". Checks auto-resume on
  the next ping (HC `manual_resume=false` default).
- Retires the orbit-cron `pause-offline-checks.py` job — its responsibility
  (suppressing alerts for offline machines) is now handled inline by the
  coordinator. The script remains in-repo for reference and one-shot recovery.

### Added
- New `hc_check_uuids` table caches slug→uuid lookups so pause is one API
  call per check after the first.

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
