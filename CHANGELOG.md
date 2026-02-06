# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
