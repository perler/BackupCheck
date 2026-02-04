# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - Repository credentials (for NAS/share access) - stored in Windows Credential Manager
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
