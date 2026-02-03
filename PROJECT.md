# BackupCheck - Internal Project Notes

## Architecture

This project monitors Macrium Reflect backup repositories by checking the filesystem
for recent `.mrimg` files, rather than using the Macrium API. This approach is simpler
and works with any backup storage location.

## Key Design Decisions

### Filesystem-based monitoring
- Checks for `.mrimg` files modified within the configured time window
- No dependency on Macrium Reflect API or license
- Works with any network share or local path

### healthchecks.io auto-provisioning
- Uses `?create=1` parameter to auto-create checks on first ping
- Eliminates need to pre-configure checks in healthchecks.io
- Check names follow `{companyId}-{machineName}` pattern for easy identification

### Skip running backups
- Checks for `backup_running*` files to avoid false alerts during active backups
- Macrium creates these files while backup is in progress

### Credential-based scheduled task
- Runs as a specific user (not SYSTEM) to access network shares
- Credentials validated during installation

## File Structure

- `Monitor-Backups.ps1` - Core monitoring logic, runs hourly
- `Install-BackupMonitor.ps1` - One-time setup, creates config and scheduled task
- `config.json` - Runtime configuration (gitignored, contains company-specific settings)
- `.env` - Credentials (gitignored, contains ping key)

## Testing

1. Run `Monitor-Backups.ps1` manually to verify detection logic
2. Check healthchecks.io dashboard for created checks
3. Verify scheduled task in Task Scheduler
4. Test alert by letting a check go stale

## Future Improvements

- [ ] Email summary report option
- [ ] Support for multiple ping keys (different projects)
- [ ] Backup size tracking
- [ ] Historical backup statistics
- [ ] Web dashboard for local status view
