# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
