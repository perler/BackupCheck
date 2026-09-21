<#
.SYNOPSIS
    Monitors Macrium Reflect backup repositories and reports status to healthchecks.io.

.DESCRIPTION
    This script scans configured backup repositories for recent .mrimg backup files.
    For each machine directory found, it checks if a backup was completed within the
    configured time window and reports the status to healthchecks.io.

    v2.0 adds: self-updating, HC API caching, structured logging, meta-monitoring.
    v2.1 adds: coordinator API integration with direct-ping fallback.
    v2.3 adds: flat repositories that name their own machine, for Macrium
    destinations that write backup files directly into the destination with
    no per-machine subdirectory to take a name from.
    v2.5 adds: air-gap media (USB Copy targets) are walked and every machine's
    newest image chain is asserted restorable (a -00-00 base exists and every
    member carries the Macrium end-of-file marker); a run in which no
    configured repository is reachable no longer reports the monitor healthy.
    v2.6 adds: leftover .error_loading files are deleted automatically once
    they are old enough and no backup is running for that machine; a deleted
    error file's image set is then verified with mrverify.exe, detached, and
    keeps the check failing until a newer image set exists if it fails;
    stale-but-intact workstations/notebooks are now reported to the
    coordinator instead of silently skipped, so it can weigh Atera's
    online/offline state instead of them running out their own HC period
    while switched off (the direct-to-healthchecks.io fallback keeps
    skipping them, unchanged, when there's no coordinator to make that call).

.NOTES
    Version: 2.6.0
    Requires: PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$EnvPath,

    [Parameter()]
    [switch]$SkipUpdateCheck
)

$ErrorActionPreference = "Stop"

# Force TLS 1.2 for all HTTPS connections (required by healthchecks.io)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Script version
$script:Version = "2.6.0"

# A Macrium .mrimg that was written to completion carries this ASCII marker
# inside its last 64 bytes; a truncated copy does not. Proven on RAHR's USB
# media 2026-08-16 (28/28 files of a known-good chain carry it, three copies
# that died mid-write do not). One 64-byte read per file, whatever its size.
$script:MacriumEndMarker = "__79241006_2651_11D4_"

# Track connections we've made for cleanup
$script:MountedShares = @()

# Macrium image-set verification (v2.6): a password, if configured, never
# touches disk or a log line - it travels to the detached mrverify process
# only via this environment variable, set immediately before the process is
# started and cleared immediately after (the child already has its own
# inherited copy by then).
$script:VerifyPasswordEnvVar = "BACKUPCHECK_VERIFY_PW"

# Determine script directory (handles both direct execution and -File invocation)
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ScriptDir) { $ScriptDir = Get-Location }

# Set default paths if not provided
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir "config.json" }
if (-not $EnvPath) { $EnvPath = Join-Path $ScriptDir ".env" }

# Cache and state file paths
$script:ConfigCachePath = Join-Path $ScriptDir ".configured-checks.json"
$script:UpdateCheckPath = Join-Path $ScriptDir ".last-update-check"
$script:LogPath = Join-Path $ScriptDir "backupcheck.log"

#region Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes a log entry to console and log file with timestamp.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet("INFO", "WARN", "ERROR", "OK", "FAIL", "SKIP")]
        [string]$Level = "INFO",

        [Parameter()]
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    # Console output with color
    Write-Host $logLine -ForegroundColor $Color

    # File output (append)
    try {
        $logLine | Out-File -FilePath $script:LogPath -Append -Encoding UTF8
    }
    catch {
        # Don't let logging failures kill the script
    }
}

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Removes log entries older than 7 days.
    #>
    if (-not (Test-Path $script:LogPath)) { return }

    try {
        $cutoff = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
        $lines = Get-Content $script:LogPath -ErrorAction SilentlyContinue
        if (-not $lines) { return }

        $kept = $lines | Where-Object {
            if ($_ -match '^\[(\d{4}-\d{2}-\d{2})') {
                $Matches[1] -ge $cutoff
            }
            else {
                $true  # Keep lines without dates (shouldn't happen, but safe)
            }
        }

        $kept | Out-File -FilePath $script:LogPath -Encoding UTF8 -Force
    }
    catch {
        # Silently ignore rotation failures
    }
}

function Get-EnvFile {
    <#
    .SYNOPSIS
        Reads a .env file and returns a hashtable of key-value pairs.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $env = @{}

    if (-not (Test-Path $Path)) {
        throw "Environment file not found: $Path"
    }

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $env[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }

    return $env
}

function Connect-ShareWithCredentials {
    <#
    .SYNOPSIS
        Connects to a UNC share using provided credentials via net use.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SharePath,

        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$Password
    )

    # Extract server name from UNC path (e.g., \\nas002\backup_srv -> \\nas002)
    if ($SharePath -match '^(\\\\[^\\]+)') {
        $serverPath = $Matches[1]
    }
    else {
        Write-Log "Invalid UNC path: $SharePath" -Level WARN -Color Yellow
        return $false
    }

    # Check if we can already access the share (credentials may be cached)
    if (Test-Path $SharePath -ErrorAction SilentlyContinue) {
        Write-Log "Already have access to $SharePath" -Level INFO
        return $true
    }

    try {
        # First, try to disconnect any existing connection to avoid "multiple connections" error
        try { $null = net use $serverPath /delete /y 2>&1 } catch { }

        # Connect with credentials
        $result = net use $serverPath /user:$Username $Password 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:MountedShares += $serverPath
            Write-Log "Connected to $serverPath" -Level INFO
            return $true
        }
        else {
            Write-Log "Failed to connect to $serverPath : $result" -Level WARN -Color Yellow
            return $false
        }
    }
    catch {
        Write-Log "Error connecting to $serverPath : $_" -Level WARN -Color Yellow
        return $false
    }
}

function Disconnect-MountedShares {
    <#
    .SYNOPSIS
        Disconnects all shares mounted by this script.
    #>
    foreach ($share in $script:MountedShares) {
        try {
            $null = net use $share /delete /y 2>&1
        }
        catch {
            # Silently ignore disconnect failures
        }
    }
    $script:MountedShares = @()
}

function Get-BackupRepositories {
    <#
    .SYNOPSIS
        Gets the list of backup repositories from config or auto-detection.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $repositories = @()

    # Try auto-detection if enabled
    if ($Config.autoDetectRepositories) {
        $mrserverPath = "C:\Program Files\Macrium\SiteManager\mrserver.exe"
        if (Test-Path $mrserverPath) {
            try {
                Write-Log "Auto-detecting repositories via mrserver.exe..."
                $output = & $mrserverPath --action get-repo-status --outputtoconsole 2>&1
                $repoData = $output | ConvertFrom-Csv

                foreach ($repo in $repoData) {
                    $repoPath = $repo."Repository Path"
                    if ($repoPath -and (Test-Path $repoPath -ErrorAction SilentlyContinue)) {
                        $repositories += $repoPath
                    }
                }

                if ($repositories.Count -gt 0) {
                    Write-Log "Auto-detected $($repositories.Count) repositories"
                    # Auto-detected repos never carry a configured machine name —
                    # each subdirectory is enumerated as before. The leading comma
                    # is load-bearing: without it, PowerShell unrolls a single-
                    # element array back to the bare hashtable when there is
                    # exactly one repository, so the caller silently gets a
                    # Hashtable instead of an array of one.
                    return ,@($repositories | ForEach-Object { @{ Path = $_; Machine = $null } })
                }
            }
            catch {
                Write-Log "Auto-detection failed: $_" -Level WARN -Color Yellow
            }
        }
    }

    # Fall back to configured repositories. Normalise every entry to one
    # shape (Path/Machine) so nothing downstream has to ask "is this a
    # string?" — a plain string is an enumerating repository (Machine =
    # $null, today's behaviour unchanged); an object with a `path` property
    # (ConvertFrom-Json yields a PSCustomObject here, never a string) is a
    # flat repository naming its own machine. The leading comma before @()
    # is load-bearing (see the auto-detect branch above): most clients run
    # with exactly one configured repository, and without it PowerShell
    # unrolls that single-element array back to a bare hashtable.
    if ($Config.repositories -and $Config.repositories.Count -gt 0) {
        return ,@($Config.repositories | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "path") {
                @{ Path = $_.path; Machine = $_.machine }
            }
            else {
                @{ Path = $_; Machine = $null }
            }
        })
    }

    throw "No repositories configured or detected"
}

function Get-CheckSlug {
    <#
    .SYNOPSIS
        Builds a healthchecks.io slug from company ID and machine name.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CompanyId,

        [Parameter(Mandatory)]
        [string]$MachineName
    )

    return "$CompanyId-$MachineName".ToLower()
}

function Test-BackupHealth {
    <#
    .SYNOPSIS
        Checks if a machine directory contains recent backup files.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$MaxAgeHours,

        [Parameter(Mandatory)]
        [string]$FilePattern,

        [Parameter()]
        [bool]$SkipIfRunning = $true,

        [Parameter()]
        [string]$RunningFilePattern = "backup_running*",

        [Parameter()]
        [string]$MachineName,

        [Parameter()]
        [bool]$DeleteErrorFiles = $true,

        [Parameter()]
        [int]$ErrorFileMinAgeHours = 24
    )

    $result = @{
        Path = $Path
        MachineName = if ($MachineName) { $MachineName } else { Split-Path $Path -Leaf }
        IsHealthy = $false
        IsFresh = $false
        IsSkipped = $false
        SkipReason = $null
        LatestBackup = $null
        BackupAge = $null
        BackupCount = 0
        HasErrorFiles = $false
        ErrorFileCount = 0
        DeletedErrorFileCount = 0
        DeletedErrorFilePaths = @()
        IsWarning = $false
    }

    # Check if backup is currently running
    if ($SkipIfRunning) {
        $runningFiles = Get-ChildItem -Path $Path -Filter $RunningFilePattern -ErrorAction SilentlyContinue
        if ($runningFiles) {
            $result.IsSkipped = $true
            $result.SkipReason = "Backup in progress"
            return $result
        }
    }

    # Check for error files (.mrimg.error_loading) - these indicate corruption.
    # Macrium appends a numeric suffix when the target name is already taken
    # (.error_loading1, .error_loading2, ...). The plain "*.error_loading" filter
    # missed those, so the alert undercounted: STPH WKS011 reported 6 corrupted
    # files on 2026-08-20 when 11 were on disk. Filter wide, then match exactly.
    $errorFiles = @(Get-ChildItem -Path $Path -Filter "*.error_loading*" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.error_loading\d*$' })

    # Leftover .error_loading files are safe to remove: we already know (by
    # having reached this point) that no backup is running for this machine,
    # and the age floor keeps a file from a copy that just died - and hasn't
    # aged into the running-marker window - from being deleted out from under
    # a retry. A delete that fails (e.g. the task account has no delete right
    # on the share) is logged and left in place; it keeps counting as a
    # corrupted file exactly as before.
    if ($DeleteErrorFiles -and $errorFiles) {
        $deleteCutoff = (Get-Date).AddHours(-$ErrorFileMinAgeHours)
        $candidates = @($errorFiles | Where-Object { $_.LastWriteTime -le $deleteCutoff })
        $deletedPaths = @()
        foreach ($f in $candidates) {
            try {
                $sizeBytes = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-Log "Deleted leftover error file: $($f.FullName) ($sizeBytes bytes)" -Level INFO
                $deletedPaths += $f.FullName
            }
            catch {
                Write-Log "Could not delete leftover error file: $($f.FullName): $($_.Exception.Message)" -Level WARN -Color Yellow
            }
        }
        if ($deletedPaths.Count -gt 0) {
            $result.DeletedErrorFileCount = $deletedPaths.Count
            $result.DeletedErrorFilePaths = $deletedPaths
            $errorFiles = @($errorFiles | Where-Object { $deletedPaths -notcontains $_.FullName })
        }
    }

    if ($errorFiles) {
        $result.HasErrorFiles = $true
        $result.ErrorFileCount = ($errorFiles | Measure-Object).Count
    }

    # Find backup files (exclude .error_loading and other non-backup extensions)
    $cutoffTime = (Get-Date).AddHours(-$MaxAgeHours)
    $backupFiles = Get-ChildItem -Path $Path -Filter $FilePattern -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -gt $cutoffTime -and
            $_.Name -notmatch '\.(error_loading\d*|tmp)$'
        }

    $result.BackupCount = ($backupFiles | Measure-Object).Count

    if ($result.BackupCount -gt 0) {
        $latestFile = $backupFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $result.LatestBackup = $latestFile.FullName
        $result.BackupAge = [math]::Round(((Get-Date) - $latestFile.LastWriteTime).TotalHours, 1)
        $result.IsFresh = $true
    }

    # Freshness is evaluated independently of corruption so that a repository
    # with .error_loading files cannot mask a stopped backup.
    #
    # Corruption on its own no longer fails the check. A .error_loading file sits
    # on disk until somebody deletes it by hand, so a machine that was backing up
    # perfectly went DOWN and stayed DOWN: STPH WKS011 mailed a DOWN alert every
    # day from 13. to 20.08.2026 while its image chain was unbroken and current,
    # and the alert text ("corrupted backup file(s) detected") read as an active
    # backup failure. Corrupt-but-fresh is now a warning - the check stays UP and
    # the ping body carries the WARNING line so the cleanup is still visible.
    # Corrupt AND stale is the case this detection exists for, and still fails.
    $result.IsHealthy = $result.IsFresh
    $result.IsWarning = ($result.IsFresh -and $result.HasErrorFiles)

    return $result
}

function Test-MacriumEndMarker {
    <#
    .SYNOPSIS
        Returns $true if the file's last 64 bytes contain the Macrium end-of-file
        marker, i.e. the image was written to completion.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 64) { return $false }
        $null = $stream.Seek(-64, [IO.SeekOrigin]::End)
        $buffer = New-Object byte[] 64
        $read = $stream.Read($buffer, 0, 64)
        $tail = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        return $tail.Contains($script:MacriumEndMarker)
    }
    catch {
        # Unreadable counts as unfinished: a copy we cannot read the end of is
        # not one we can call restorable.
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Test-AirGapChain {
    <#
    .SYNOPSIS
        Asserts that a machine's newest image chain on an air-gap medium is
        restorable: a -00-00 base exists AND every member carries the end marker.
    .DESCRIPTION
        Chain members are files named <16-hex-id>-NN-NN.mrimg. Files with any
        other name (USB Copy "_Conflict" artefacts, .tmp fragments) are not
        visible to Macrium, so they are counted but never satisfy the assertion.
        The newest chain is the one holding the most recently written member.
        A member without the marker that was written within the last hour is
        treated as a copy still in progress, not as a failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$MachineName
    )

    $result = @{
        MachineName = $MachineName
        Path = $Path
        Status = "FAIL"        # OK | FAIL | BUSY
        Detail = ""
        ChainId = $null
        FileCount = 0
        OrphanCount = 0
    }

    $allFiles = @(Get-ChildItem -Path $Path -Filter "*.mrimg*" -Recurse -File -ErrorAction SilentlyContinue)
    $chains = @{}
    foreach ($f in $allFiles) {
        if ($f.Name -match '^([0-9A-Fa-f]{16})-\d{2}-\d{2}\.mrimg$') {
            $id = $Matches[1].ToUpper()
            if (-not $chains.ContainsKey($id)) { $chains[$id] = @() }
            $chains[$id] += $f
        }
        else {
            $result.OrphanCount++
        }
    }

    if ($chains.Count -eq 0) {
        $result.Detail = "no image chain on medium ($($allFiles.Count) file(s), none named as a chain member)"
        return $result
    }

    # Newest chain = the one whose most recent member was written last.
    $newestId = $null
    $newestTime = [datetime]::MinValue
    foreach ($id in $chains.Keys) {
        $t = ($chains[$id] | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        if ($t -gt $newestTime) { $newestTime = $t; $newestId = $id }
    }
    $members = @($chains[$newestId] | Sort-Object Name)
    $result.ChainId = $newestId
    $result.FileCount = $members.Count
    $newestStamp = $newestTime.ToString("yyyy-MM-dd HH:mm")

    $hasBase = @($members | Where-Object { $_.Name -match '-00-00\.mrimg$' }).Count -gt 0

    $unfinished = @()
    $busy = @()
    $inProgressCutoff = (Get-Date).AddHours(-1)
    foreach ($m in $members) {
        if (-not (Test-MacriumEndMarker -Path $m.FullName)) {
            if ($m.LastWriteTime -gt $inProgressCutoff) { $busy += $m.Name } else { $unfinished += $m.Name }
        }
    }

    $orphanNote = if ($result.OrphanCount -gt 0) { "; $($result.OrphanCount) file(s) outside any chain (conflict/tmp artefacts)" } else { "" }

    if (-not $hasBase) {
        $result.Detail = "newest chain $newestId has NO -00-00 base ($($members.Count) file(s), newest $newestStamp)$orphanNote"
    }
    elseif ($unfinished.Count -gt 0) {
        $result.Detail = "chain $newestId`: $($unfinished.Count) of $($members.Count) file(s) unfinished (no end marker): $($unfinished -join ', ')$orphanNote"
    }
    elseif ($busy.Count -gt 0) {
        $result.Status = "BUSY"
        $result.Detail = "chain $newestId`: copy in progress ($($busy -join ', ') written within the last hour)$orphanNote"
    }
    else {
        $result.Status = "OK"
        $result.Detail = "chain $newestId`: base + $($members.Count - 1) file(s), $($members.Count)/$($members.Count) complete, newest $newestStamp$orphanNote"
    }

    return $result
}

function Get-MrimgChainId {
    <#
    .SYNOPSIS
        Parses the 16-hex-char Macrium image-set ID out of a .mrimg (or
        .mrimg.error_loading<N>) file name. Returns $null if the name
        doesn't match.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    if ($FileName -match '^([0-9A-Fa-f]{16})-\d{2}-\d{2}\.mrimg(\.error_loading\d*)?$') {
        return $Matches[1].ToUpper()
    }
    return $null
}

function Get-NewestChainId {
    <#
    .SYNOPSIS
        Returns the image-set ID whose newest member was written most
        recently in $Path, or $null if no chain member is found. Same
        "newest chain" logic as Test-AirGapChain above, without the
        base/end-marker restorability checks that function also does -
        here we only need to pick WHICH image set to verify.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $files = @(Get-ChildItem -Path $Path -Filter "*.mrimg" -Recurse -File -ErrorAction SilentlyContinue)
    $chains = @{}
    foreach ($f in $files) {
        $id = Get-MrimgChainId -FileName $f.Name
        if ($id) {
            if (-not $chains.ContainsKey($id)) { $chains[$id] = @() }
            $chains[$id] += $f
        }
    }
    if ($chains.Count -eq 0) { return $null }

    $newestId = $null
    $newestTime = [datetime]::MinValue
    foreach ($id in $chains.Keys) {
        $t = ($chains[$id] | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        if ($t -gt $newestTime) { $newestTime = $t; $newestId = $id }
    }
    return $newestId
}

function Get-NewestBackupTime {
    <#
    .SYNOPSIS
        Returns the LastWriteTime of the most recent backup file under
        $Path (no age cutoff), or $null if none. Used to tell whether a
        newer image set has appeared since a Macrium verify failed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FilePattern
    )

    $files = Get-ChildItem -Path $Path -Filter $FilePattern -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.(error_loading\d*|tmp)$' }
    if (-not $files) { return $null }
    return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
}

function Find-MrverifyExe {
    <#
    .SYNOPSIS
        Locates mrverify.exe: a configured path, then the Macrium Reflect
        install directory (via the standard Uninstall registry entry),
        then the default install path. Returns $null - never throws - if
        none is found, so a missing tool only ever produces a WARN.
    .NOTES
        mrverify.exe is a separate download from Macrium
        (updates.macrium.com/reflect/utilities/mrverify.exe), not part of
        the Reflect installer - on a given client it may simply not be on
        disk anywhere, in which case this always falls through to $null.
    #>
    param(
        [Parameter()]
        [string]$ConfiguredPath
    )

    if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return (Resolve-Path -LiteralPath $ConfiguredPath).Path
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        try {
            $entries = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Macrium*Reflect*' -and $_.InstallLocation }
            foreach ($entry in $entries) {
                $candidate = Join-Path $entry.InstallLocation 'mrverify.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
        }
        catch {
            # Registry provider unavailable (e.g. not Windows) - fall through.
        }
    }

    $default = 'C:\Program Files\Macrium\Reflect\mrverify.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf -ErrorAction SilentlyContinue) {
        return (Resolve-Path -LiteralPath $default).Path
    }

    return $null
}

function New-VerifyChildCommand {
    <#
    .SYNOPSIS
        Builds the PowerShell source for the detached child process that
        runs mrverify.exe synchronously and writes its exit code to disk.
    .DESCRIPTION
        The Macrium image password (if any) is NOT embedded in this text -
        the child reads it back out of $env:BACKUPCHECK_VERIFY_PW, which it
        inherits from the parent at launch (see Start-ImageSetVerify). That
        keeps the password out of this generated script and out of every
        Write-Log line; it still appears as an mrverify.exe process argument
        on the box, which is inherent to mrverify's own command-line-only
        interface (confirmed against Macrium's own KB page).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MrverifyPath,

        [Parameter(Mandatory)]
        [string]$TargetPattern,

        [Parameter()]
        [bool]$Recurse = $true,

        [Parameter()]
        [bool]$UsePassword = $false,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$ResultPath
    )

    $mrverifyEsc = $MrverifyPath.Replace("'", "''")
    $targetEsc = $TargetPattern.Replace("'", "''")
    $logEsc = $LogPath.Replace("'", "''")
    $resultEsc = $ResultPath.Replace("'", "''")

    $argLines = @("'$targetEsc'")
    if ($UsePassword) { $argLines += "'-p'", "`$env:$script:VerifyPasswordEnvVar" }
    if ($Recurse) { $argLines += "'-r'" }
    $argLines += "'-l'", "'$logEsc'"
    $argListText = $argLines -join ', '

    return @"
`$ErrorActionPreference = 'Continue'
`$exitCode = -1
try {
    `$mrArgs = @($argListText)
    `$p = Start-Process -FilePath '$mrverifyEsc' -ArgumentList `$mrArgs -NoNewWindow -Wait -PassThru
    `$exitCode = `$p.ExitCode
}
catch {
    `$exitCode = -1
}
finally {
    if (Test-Path Env:\$script:VerifyPasswordEnvVar) { Remove-Item Env:\$script:VerifyPasswordEnvVar -ErrorAction SilentlyContinue }
}
@{ exitCode = `$exitCode; finishedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Out-File -FilePath '$resultEsc' -Encoding UTF8 -Force
"@
}

function Start-ImageSetVerify {
    <#
    .SYNOPSIS
        Launches mrverify.exe DETACHED (fire-and-forget) via a small hidden
        PowerShell child that waits for it and writes the exit code to
        $ResultPath. Returns immediately with the child's PID and start
        time - a verify over SMB can run for hours and the monitor itself
        runs hourly, so nothing here waits for it to finish.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MrverifyPath,

        [Parameter(Mandatory)]
        [string]$TargetPattern,

        [Parameter()]
        [bool]$Recurse = $true,

        [Parameter()]
        [string]$Password,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$ResultPath,

        [Parameter()]
        [string]$ShellExe = 'powershell.exe'
    )

    $usePassword = [bool]$Password
    $childScript = New-VerifyChildCommand -MrverifyPath $MrverifyPath -TargetPattern $TargetPattern `
        -Recurse $Recurse -UsePassword $usePassword -LogPath $LogPath -ResultPath $ResultPath

    $bytes = [Text.Encoding]::Unicode.GetBytes($childScript)
    $encoded = [Convert]::ToBase64String($bytes)
    $procArgs = @("-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded)

    if ($usePassword) { Set-Item -Path "Env:$script:VerifyPasswordEnvVar" -Value $Password }
    try {
        $startArgs = @{
            FilePath = $ShellExe
            ArgumentList = $procArgs
            PassThru = $true
        }
        # $IsWindows doesn't exist on Windows PowerShell 5.1 (the production
        # target, Windows-only by definition); on pwsh it's $true on Windows
        # and $false elsewhere. -ne $false covers "true" and "undefined" the
        # same way, so WindowStyle is only skipped on a real non-Windows pwsh.
        if ($IsWindows -ne $false) { $startArgs.WindowStyle = 'Hidden' }
        $proc = Start-Process @startArgs
    }
    finally {
        if ($usePassword) { Remove-Item "Env:$script:VerifyPasswordEnvVar" -ErrorAction SilentlyContinue }
    }

    return @{ Pid = $proc.Id; StartTime = $proc.StartTime }
}

function Update-ImageSetVerify {
    <#
    .SYNOPSIS
        Per-machine state machine for the "verify after error-file cleanup"
        feature. Call once per machine per run; reads/writes one state file
        per machine in $StateDir.
    .DESCRIPTION
        - No state, no deletions this run: no-op.
        - No state, deletions this run: derive the image set from the
          deleted file names (or the newest chain if that fails) and
          launch a verify.
        - State exists, process still alive: no-op (no second launch).
        - State exists, process dead, result says exit 0: report
          JustPassed once, clear the state.
        - State exists, process dead, result says exit 1: report
          ForceFail, and KEEP the state (so it forces a fail every run)
          until a newer backup than the one that failed appears.
        - State exists, process dead, no result file: WARN and retry once;
          if the retry also dies without a result, give up and clear it.
    .OUTPUTS
        @{ ForceFail; FailMessage; JustPassed; ImageId }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$StateDir,

        [Parameter(Mandatory)]
        [string]$Slug,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter(Mandatory)]
        [string]$MachinePath,

        [Parameter()]
        [string[]]$DeletedErrorFilePaths = @(),

        [Parameter(Mandatory)]
        [string]$FilePattern,

        [Parameter()]
        [string]$MrverifyPath,

        [Parameter()]
        [string]$VerifyPassword,

        [Parameter()]
        [bool]$Recurse = $true,

        [Parameter()]
        [string]$ShellExe = 'powershell.exe'
    )

    $statePath = Join-Path $StateDir "$Slug.json"
    $verify = @{ ForceFail = $false; FailMessage = ''; JustPassed = $false; ImageId = $null }

    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }

    if ($state) {
        $alive = $false
        try {
            $proc = Get-Process -Id $state.pid -ErrorAction Stop
            if ($state.startTime) {
                $recorded = [datetime]$state.startTime
                # PIDs can be reused by the OS; comparing the recorded start
                # time against the live process's own start time catches
                # that instead of trusting a bare PID match.
                if ([math]::Abs(($proc.StartTime - $recorded).TotalSeconds) -le 2) { $alive = $true }
            }
            else {
                $alive = $true
            }
        }
        catch { $alive = $false }

        if ($alive) {
            Write-Log "  Macrium verify still running for ${MachineName} (image set $($state.imageId), PID $($state.pid), started $($state.startTime))" -Level INFO
            $verify.ImageId = $state.imageId
            return $verify
        }

        # Process is not alive any more - look for a result.
        if (Test-Path -LiteralPath $state.resultPath) {
            $result = $null
            try { $result = Get-Content -LiteralPath $state.resultPath -Raw | ConvertFrom-Json } catch { $result = $null }

            if ($result -and ($result.PSObject.Properties.Name -contains 'exitCode')) {
                if ([int]$result.exitCode -eq 0) {
                    Write-Log "  Macrium verify PASSED for ${MachineName} (image set $($state.imageId)): $($state.logPath)" -Level OK -Color Green
                    $verify.JustPassed = $true
                    $verify.ImageId = $state.imageId
                    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $state.resultPath -Force -ErrorAction SilentlyContinue
                    $state = $null
                }
                else {
                    $newest = Get-NewestBackupTime -Path $MachinePath -FilePattern $FilePattern
                    $failedAt = if ($state.newestMemberTime) { [datetime]$state.newestMemberTime } else { [datetime]::MinValue }
                    if ($newest -and $newest -gt $failedAt) {
                        Write-Log "  Macrium verify failure for ${MachineName} (image set $($state.imageId)) cleared - a newer backup exists" -Level INFO
                        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $state.resultPath -Force -ErrorAction SilentlyContinue
                        $state = $null
                    }
                    else {
                        $verify.ForceFail = $true
                        $verify.ImageId = $state.imageId
                        $verify.FailMessage = "image set $($state.imageId) failed Macrium verification, see $($state.logPath)"
                        return $verify
                    }
                }
            }
            else {
                # Malformed/unreadable result file - treat like dead-without-result below.
                Remove-Item -LiteralPath $state.resultPath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($state -and -not (Test-Path -LiteralPath $state.resultPath)) {
            # Dead without a usable result file.
            if ($state.retried) {
                Write-Log "  Macrium verify for ${MachineName} (image set $($state.imageId)) is gone with no result after one retry - giving up" -Level WARN -Color Yellow
                Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                $state = $null
            }
            else {
                Write-Log "  Macrium verify for ${MachineName} (image set $($state.imageId), PID $($state.pid)) is gone with no result - retrying once" -Level WARN -Color Yellow
                if ($MrverifyPath) {
                    $target = Join-Path $MachinePath "$($state.imageId)-*.mrimg"
                    $launch = Start-ImageSetVerify -MrverifyPath $MrverifyPath -TargetPattern $target -Recurse $Recurse `
                        -Password $VerifyPassword -LogPath $state.logPath -ResultPath $state.resultPath -ShellExe $ShellExe
                    $newState = @{
                        imageId = $state.imageId
                        machineName = $MachineName
                        targetPattern = $target
                        startTime = $launch.StartTime.ToString('o')
                        pid = $launch.Pid
                        logPath = $state.logPath
                        resultPath = $state.resultPath
                        newestMemberTime = $state.newestMemberTime
                        retried = $true
                    }
                    $newState | ConvertTo-Json | Out-File -FilePath $statePath -Encoding UTF8 -Force
                }
                else {
                    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                }
                $verify.ImageId = $state.imageId
                return $verify
            }
        }
    }

    # No pending/persisting state (never existed, or just cleared above).
    if ($DeletedErrorFilePaths -and $DeletedErrorFilePaths.Count -gt 0) {
        if (-not $MrverifyPath) {
            Write-Log "  Verify skipped for ${MachineName}: mrverify.exe not found" -Level WARN -Color Yellow
            return $verify
        }

        $ids = @($DeletedErrorFilePaths | ForEach-Object { Get-MrimgChainId -FileName (Split-Path $_ -Leaf) } |
            Where-Object { $_ } | Select-Object -Unique)

        $imageId = $null
        if ($ids.Count -eq 1) {
            $imageId = $ids[0]
        }
        elseif ($ids.Count -gt 1) {
            # Deletions from more than one image set in the same run - verify
            # the newest of the affected sets rather than launching several.
            $imageId = $ids | Sort-Object { Get-NewestBackupTime -Path $MachinePath -FilePattern "$_*.mrimg" } -Descending | Select-Object -First 1
        }
        else {
            # Couldn't parse an ID from any deleted file name - fall back to
            # the newest chain on disk (same logic Test-AirGapChain uses).
            $imageId = Get-NewestChainId -Path $MachinePath
        }

        if (-not $imageId) {
            Write-Log "  Verify skipped for ${MachineName}: could not determine an image set to verify" -Level WARN -Color Yellow
            return $verify
        }

        $target = Join-Path $MachinePath "$imageId-*.mrimg"
        $logPath = Join-Path $StateDir "$Slug.mrverify.log"
        $resultPath = Join-Path $StateDir "$Slug.result.json"
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

        $newestMemberTime = Get-NewestBackupTime -Path $MachinePath -FilePattern "$imageId-*.mrimg"

        $launch = Start-ImageSetVerify -MrverifyPath $MrverifyPath -TargetPattern $target -Recurse $Recurse `
            -Password $VerifyPassword -LogPath $logPath -ResultPath $resultPath -ShellExe $ShellExe

        $newState = @{
            imageId = $imageId
            machineName = $MachineName
            targetPattern = $target
            startTime = $launch.StartTime.ToString('o')
            pid = $launch.Pid
            logPath = $logPath
            resultPath = $resultPath
            newestMemberTime = if ($newestMemberTime) { $newestMemberTime.ToString('o') } else { $null }
            retried = $false
        }
        $newState | ConvertTo-Json | Out-File -FilePath $statePath -Encoding UTF8 -Force
        Write-Log "  Started Macrium verify for ${MachineName}: image set $imageId (PID $($launch.Pid), log $logPath)" -Level INFO
        $verify.ImageId = $imageId
    }

    return $verify
}

function Get-DeviceTypeSettings {
    <#
    .SYNOPSIS
        Returns tag, timeout, and grace settings based on device name pattern.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MachineName
    )

    $name = $MachineName.ToUpper()

    if ($name -match "^WKS") {
        return @{
            Tag = "wks"
            Timeout = 345600    # 4 days in seconds
            Grace = 21600       # 6 hours in seconds
        }
    }
    elseif ($name -match "^NB") {
        return @{
            Tag = "nb"
            Timeout = 691200    # 8 days in seconds
            Grace = 21600       # 6 hours in seconds
        }
    }
    elseif ($name -match "^SRV") {
        return @{
            Tag = "srv"
            Timeout = 86400     # 1 day in seconds
            Grace = 64800       # 18 hours in seconds
        }
    }
    else {
        return @{
            Tag = $null
            Timeout = $null
            Grace = $null
        }
    }
}

function Get-ConfigCache {
    <#
    .SYNOPSIS
        Loads the HC API configuration cache from disk.
    #>
    if (-not (Test-Path $script:ConfigCachePath)) {
        return @{}
    }

    try {
        $raw = Get-Content $script:ConfigCachePath -Raw | ConvertFrom-Json
        # Convert PSCustomObject to hashtable
        $cache = @{}
        $raw.PSObject.Properties | ForEach-Object {
            $cache[$_.Name] = $_.Value
        }
        return $cache
    }
    catch {
        return @{}
    }
}

function Save-ConfigCache {
    <#
    .SYNOPSIS
        Saves the HC API configuration cache to disk.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    try {
        $Cache | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:ConfigCachePath -Encoding UTF8 -Force
    }
    catch {
        Write-Log "Failed to save config cache: $_" -Level WARN -Color Yellow
    }
}

function Send-HealthCheck {
    <#
    .SYNOPSIS
        Sends a ping to healthchecks.io and configures check via Management API (with caching).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [string]$PingKey,

        [Parameter(Mandatory)]
        [string]$Slug,

        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter()]
        [string]$Message = "",

        [Parameter()]
        [string[]]$Tags = @(),

        [Parameter()]
        [string]$ApiKey = "",

        [Parameter()]
        [string]$MachineName = "",

        [Parameter()]
        [hashtable]$ConfigCache = @{}
    )

    $endpoint = if ($Success) {
        "$BaseUrl/$PingKey/$Slug"
    }
    else {
        "$BaseUrl/$PingKey/$Slug/fail"
    }

    # Add auto-provisioning parameter
    $endpoint += "?create=1"

    try {
        $params = @{
            Uri = $endpoint
            Method = "POST"
            Body = $Message
            ContentType = "text/plain"
            UseBasicParsing = $true
        }

        $response = Invoke-WebRequest @params

        # Configure check via Management API v1 (with caching to reduce API calls)
        if ($ApiKey -and $MachineName) {
            $deviceSettings = Get-DeviceTypeSettings -MachineName $MachineName

            # Build desired tags
            $allTags = $Tags.Clone()
            if ($deviceSettings.Tag -and $deviceSettings.Tag -notin $allTags) {
                $allTags += $deviceSettings.Tag
            }
            $tagsString = $allTags -join " "

            # Build desired config for comparison
            $desiredConfig = @{
                tags = $tagsString
                timeout = $deviceSettings.Timeout
                grace = $deviceSettings.Grace
            }

            # Check cache to see if configuration is already applied
            $cached = $ConfigCache[$Slug]
            $needsUpdate = $true

            if ($cached) {
                $cacheAge = if ($cached.configuredAt) {
                    ((Get-Date) - [datetime]::Parse($cached.configuredAt)).TotalDays
                } else { 999 }

                if ($cacheAge -lt 7 -and
                    $cached.tags -eq $desiredConfig.tags -and
                    $cached.timeout -eq $desiredConfig.timeout -and
                    $cached.grace -eq $desiredConfig.grace) {
                    $needsUpdate = $false
                }
            }

            if ($needsUpdate) {
                try {
                    $headers = @{ "X-Api-Key" = $ApiKey }
                    $checks = Invoke-RestMethod -Uri "https://healthchecks.io/api/v1/checks/" -Headers $headers -Method Get
                    $check = $checks.checks | Where-Object { $_.slug -eq $Slug }
                    if ($check -and $check.update_url) {
                        $updateData = @{ tags = $tagsString }
                        if ($deviceSettings.Timeout) { $updateData.timeout = $deviceSettings.Timeout }
                        if ($deviceSettings.Grace) { $updateData.grace = $deviceSettings.Grace }

                        $updateBody = $updateData | ConvertTo-Json
                        Invoke-RestMethod -Uri $check.update_url -Headers $headers -Method POST -Body $updateBody -ContentType "application/json" | Out-Null

                        # Update cache
                        $ConfigCache[$Slug] = @{
                            tags = $tagsString
                            timeout = $deviceSettings.Timeout
                            grace = $deviceSettings.Grace
                            configuredAt = (Get-Date).ToString("yyyy-MM-dd")
                        }
                    }
                }
                catch {
                    # Silently ignore configuration update failures
                }
            }
        }

        return @{
            Success = $true
            StatusCode = $response.StatusCode
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Test-UpdateAvailable {
    <#
    .SYNOPSIS
        Checks for a newer version of BackupCheck. Supports coordinator (auth)
        and legacy GitHub raw URL (no auth).
    .OUTPUTS
        Returns @{ Manifest = ...; ApiKey = ... } if update available, $null otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UpdateUrl,

        [Parameter()]
        [string]$ApiKey,

        [Parameter()]
        [string]$Channel = "stable"
    )

    # Check if we should skip (checked within last 24h)
    if (Test-Path $script:UpdateCheckPath) {
        $lastCheck = (Get-Item $script:UpdateCheckPath).LastWriteTime
        if (((Get-Date) - $lastCheck).TotalHours -lt 24) {
            Write-Log "Update check skipped (last checked $('{0:N1}' -f ((Get-Date) - $lastCheck).TotalHours)h ago)"
            return $null
        }
    }

    # Touch the timestamp file
    try {
        [IO.File]::WriteAllText($script:UpdateCheckPath, (Get-Date).ToString("o"))
    }
    catch { }

    # Coordinator URL = ends with /api/latest. Otherwise treat as legacy GitHub raw base.
    $isCoordinator = $UpdateUrl -match '/api/latest$'
    $manifestUrl = if ($isCoordinator) { "${UpdateUrl}?channel=$Channel" } else { "$UpdateUrl/latest.json" }

    try {
        Write-Log "Checking for updates from $manifestUrl..."
        $headers = @{}
        if ($isCoordinator -and $ApiKey) { $headers["X-API-Key"] = $ApiKey }
        $latestJson = Invoke-RestMethod -Uri $manifestUrl -Headers $headers -TimeoutSec 10 -UseBasicParsing

        if (-not $latestJson.version) {
            Write-Log "No version in manifest (channel '$Channel' empty?)" -Level INFO
            return $null
        }

        $remoteVersion = [version]$latestJson.version
        $localVersion = [version]$script:Version

        if ($remoteVersion -gt $localVersion) {
            Write-Log "Update available: v$($script:Version) -> v$($latestJson.version)" -Level INFO -Color Cyan
            return @{ Manifest = $latestJson; ApiKey = $(if ($isCoordinator) { $ApiKey } else { "" }) }
        }
        else {
            Write-Log "Up to date (v$($script:Version))"
            return $null
        }
    }
    catch {
        Write-Log "Update check failed: $_" -Level WARN -Color Yellow
        return $null
    }
}

function Invoke-SelfUpdate {
    <#
    .SYNOPSIS
        Downloads and applies an update from the release URL.
    #>
    param(
        [Parameter(Mandatory)]
        $UpdateResult
    )

    $UpdateInfo = $UpdateResult.Manifest
    $apiKey = $UpdateResult.ApiKey
    $releaseUrl = $UpdateInfo.releaseUrl
    if (-not $releaseUrl) {
        Write-Log "No release URL in update info" -Level WARN -Color Yellow
        return $false
    }

    $zipPath = Join-Path $env:TEMP "BackupCheck-update.zip"
    $extractPath = Join-Path $env:TEMP "BackupCheck-update"

    try {
        # Download the release zip (with auth for coordinator URLs)
        Write-Log "Downloading update from $releaseUrl..."
        $dlHeaders = @{}
        if ($apiKey -and $releaseUrl -match '/api/download/') { $dlHeaders["X-API-Key"] = $apiKey }
        Invoke-WebRequest -Uri $releaseUrl -Headers $dlHeaders -OutFile $zipPath -UseBasicParsing -TimeoutSec 60

        # Verify SHA256 of individual files after extraction
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force
        }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # Verify checksums for each file listed in the update info
        $verified = $true
        foreach ($fileEntry in $UpdateInfo.files.PSObject.Properties) {
            $fileName = $fileEntry.Name
            $expectedHash = $fileEntry.Value.sha256
            $extractedFile = Get-ChildItem -Path $extractPath -Filter $fileName -Recurse | Select-Object -First 1

            if (-not $extractedFile) {
                Write-Log "Update file not found in archive: $fileName" -Level WARN -Color Yellow
                $verified = $false
                break
            }

            $actualHash = (Get-FileHash -Path $extractedFile.FullName -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash.ToLower()) {
                Write-Log "SHA256 mismatch for $fileName! Expected: $expectedHash, Got: $actualHash" -Level ERROR -Color Red
                $verified = $false
                break
            }
        }

        if (-not $verified) {
            Write-Log "Update verification failed, aborting update" -Level ERROR -Color Red
            return $false
        }

        # Backup current files and copy new ones
        foreach ($fileEntry in $UpdateInfo.files.PSObject.Properties) {
            $fileName = $fileEntry.Name
            $currentFile = Join-Path $ScriptDir $fileName
            $extractedFile = Get-ChildItem -Path $extractPath -Filter $fileName -Recurse | Select-Object -First 1

            if (Test-Path $currentFile) {
                $bakFile = "$currentFile.bak"
                Copy-Item -Path $currentFile -Destination $bakFile -Force
                Write-Log "Backed up $fileName -> $fileName.bak"
            }

            Copy-Item -Path $extractedFile.FullName -Destination $currentFile -Force
            Write-Log "Updated $fileName" -Level OK -Color Green
        }

        Write-Log "Update to v$($UpdateInfo.version) complete! Restarting..." -Level OK -Color Green
        return $true
    }
    catch {
        Write-Log "Update failed: $_" -Level ERROR -Color Red
        return $false
    }
    finally {
        # Cleanup temp files
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-CoordinatorReport {
    <#
    .SYNOPSIS
        Sends backup scan results to the coordinator API.
    .OUTPUTS
        Returns $true if the coordinator accepted the report, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CoordinatorUrl,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [string]$CompanyId,

        [Parameter(Mandatory)]
        [array]$MachineResults
    )

    $body = @{
        companyId = $CompanyId
        version = $script:Version
        channel = $script:Channel
        machines = @($MachineResults | ForEach-Object {
            @{
                name = $_.MachineName
                healthy = $_.IsHealthy
                backupAge = $_.BackupAge
                backupCount = $_.BackupCount
                message = $_.StatusMessage
            }
        })
    } | ConvertTo-Json -Depth 5

    try {
        $headers = @{
            "X-API-Key" = $ApiKey
            "Content-Type" = "application/json"
        }
        $response = Invoke-WebRequest -Uri $CoordinatorUrl `
            -Method POST `
            -Body $body `
            -Headers $headers `
            -UseBasicParsing `
            -TimeoutSec 30

        if ($response.StatusCode -eq 200) {
            $result = $response.Content | ConvertFrom-Json
            Write-Log "Coordinator accepted report: $($result.results.Count) machines processed" -Level OK -Color Green
            foreach ($r in $result.results) {
                Write-Log "  [$($r.slug)] verdict: $($r.verdict)"
            }
            return $true
        }
        else {
            Write-Log "Coordinator returned status $($response.StatusCode)" -Level WARN -Color Yellow
            return $false
        }
    }
    catch {
        Write-Log "Coordinator unreachable: $_ - falling back to direct HC pings" -Level WARN -Color Yellow
        return $false
    }
}

#endregion

#region Main

# Rotate logs before starting
Invoke-LogRotation

Write-Log "BackupCheck Monitor v$($script:Version)" -Color Cyan
Write-Log ("=" * 40) -Color Cyan

# Load configuration
Write-Log "Loading configuration..."
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath. Run Install-BackupMonitor.ps1 first."
}

$config = Get-Content $ConfigPath | ConvertFrom-Json

# Load environment variables
$envVars = Get-EnvFile -Path $EnvPath
$pingKey = $envVars["HC_PING_KEY"]
$apiKey = $envVars["HC_API_KEY"]

if (-not $pingKey) {
    throw "HC_PING_KEY not found in $EnvPath"
}

if (-not $apiKey) {
    Write-Log "HC_API_KEY not found in $EnvPath - tags and caching will not work" -Level WARN -Color Yellow
}

# Channel for update + reporting (default stable)
$script:Channel = if ($config.channel) { $config.channel } else { "stable" }

# Coordinator config (used for both update source and reporting)
$coordinatorUrl = if ($config.coordinatorUrl) { $config.coordinatorUrl } else { $envVars["COORDINATOR_URL"] }
$coordinatorKey = if ($config.coordinatorApiKey) { $config.coordinatorApiKey } else { $envVars["COORDINATOR_API_KEY"] }

# Self-update check
if (-not $SkipUpdateCheck) {
    # Pick update source: explicit config > coordinator (if configured) > GitHub raw fallback
    $updateUrl = if ($config.updateUrl) {
        $config.updateUrl
    }
    elseif ($coordinatorUrl -and $coordinatorKey) {
        # Derive /api/latest from coordinator base URL (which ends in /api/report)
        $coordinatorUrl -replace '/api/report$', '/api/latest'
    }
    else {
        "https://raw.githubusercontent.com/perler/BackupCheck/master"
    }

    $updateResult = Test-UpdateAvailable -UpdateUrl $updateUrl -ApiKey $coordinatorKey -Channel $script:Channel
    if ($updateResult) {
        $updated = Invoke-SelfUpdate -UpdateResult $updateResult
        if ($updated) {
            # Re-launch the updated script
            $relaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Definition)`"", "-SkipUpdateCheck")
            if ($ConfigPath) { $relaunchArgs += "-ConfigPath", "`"$ConfigPath`"" }
            if ($EnvPath) { $relaunchArgs += "-EnvPath", "`"$EnvPath`"" }
            Start-Process -FilePath "powershell.exe" -ArgumentList $relaunchArgs -NoNewWindow -Wait
            exit 0
        }
    }
}

Write-Log "Company ID: $($config.companyId)"
Write-Log "Max backup age: $($config.backupMaxAgeHours) hours"

# Leftover .error_loading files: delete automatically by default. Both keys
# are optional so a config.json from before v2.6.0 keeps working unchanged.
$deleteErrorFiles = if ($config.PSObject.Properties.Name -contains 'deleteErrorFiles') { [bool]$config.deleteErrorFiles } else { $true }
$errorFileMinAgeHours = if ($config.PSObject.Properties.Name -contains 'errorFileMinAgeHours') { [int]$config.errorFileMinAgeHours } else { 24 }

# Macrium verify after error-file cleanup: also optional, also on by
# default. mrverifyPath/verifyPassword are optional site-specific settings;
# see Find-MrverifyExe and Update-ImageSetVerify above.
$verifyAfterErrorCleanup = if ($config.PSObject.Properties.Name -contains 'verifyAfterErrorCleanup') { [bool]$config.verifyAfterErrorCleanup } else { $true }
$configuredMrverifyPath = if ($config.PSObject.Properties.Name -contains 'mrverifyPath') { [string]$config.mrverifyPath } else { $null }
$verifyPassword = if ($config.PSObject.Properties.Name -contains 'verifyPassword') { [string]$config.verifyPassword } else { $null }

$script:VerifyStateDir = Join-Path $ScriptDir ".verify-state"
$mrverifyPath = $null
if ($verifyAfterErrorCleanup) {
    if (-not (Test-Path $script:VerifyStateDir)) {
        try { New-Item -ItemType Directory -Path $script:VerifyStateDir -Force | Out-Null } catch { }
    }
    $mrverifyPath = Find-MrverifyExe -ConfiguredPath $configuredMrverifyPath
    if ($mrverifyPath) {
        Write-Log "Macrium verify tool: $mrverifyPath"
    }
    else {
        Write-Log "verify skipped: mrverify.exe not found" -Level WARN -Color Yellow
    }
}

# Build tags list: automatic tags + custom tags from config
$tags = @("backup", "macrium", $config.companyId.ToLower())
if ($config.tags -and $config.tags.Count -gt 0) {
    $tags += $config.tags
}
Write-Log "Tags: $($tags -join ', ')"

# Get repositories
$repositories = Get-BackupRepositories -Config $config
Write-Log "Monitoring $($repositories.Count) repository(ies):"
$repositories | ForEach-Object {
    if ($_.Machine) { Write-Log "  - $($_.Path) (machine: $($_.Machine))" }
    else { Write-Log "  - $($_.Path)" }
}

# Air-gap media (USB Copy targets). Each entry is the ROOT of a medium; the
# copy job mirrors the source share into it, so machines sit one level down:
# <root>\<share-copy>\<MACHINE>\...\*.mrimg. Optional - absent means no
# air-gap check, exactly today's behaviour.
$airGapRoots = @()
if ($config.airGapRepositories -and $config.airGapRepositories.Count -gt 0) {
    $airGapRoots = @($config.airGapRepositories | ForEach-Object { [string]$_ })
    Write-Log "Air-gap media ($($airGapRoots.Count)):"
    $airGapRoots | ForEach-Object { Write-Log "  - $_" }
}

# Load HC API configuration cache
$configCache = Get-ConfigCache

# Connect to shares if credentials are provided
$repoUsername = $envVars["REPO_USERNAME"]
$repoPassword = $envVars["REPO_PASSWORD"]

try {
if ($repoUsername -and $repoPassword) {
    Write-Log "Connecting to repositories with stored credentials..."
    $uniqueServers = @{}
    $connectPaths = @($repositories | ForEach-Object { $_.Path }) + $airGapRoots
    foreach ($repoPath in $connectPaths) {

        # Local (non-UNC) paths need no credentials — connecting is meaningless
        # and previously produced a spurious red "Failed: D:\srv001" line.
        # This also captures the \\server prefix in one step, so it doubles
        # as the UNC test below.
        if ($repoPath -notmatch '^(\\\\[^\\]+)') {
            continue
        }

        # Bug fix: this used to dedupe on the FULL repository path against a
        # hashtable keyed by the \\server prefix (set two lines below), so it
        # never matched and `net use /delete` + reconnect ran once per
        # repository sharing a server instead of once per server. Key the
        # lookup the same way it's populated.
        $serverPrefix = $Matches[1]

        if (-not $uniqueServers.ContainsKey($serverPrefix)) {
            $connected = Connect-ShareWithCredentials -SharePath $repoPath -Username $repoUsername -Password $repoPassword
            if ($connected) {
                Write-Log "  Connected: $repoPath" -Level OK -Color Green
            }
            else {
                Write-Log "  Failed: $repoPath" -Level FAIL -Color Red
            }
            $uniqueServers[$serverPrefix] = $true
        }
    }
}

# Phase 1: Scan all repositories and collect results
$results = @()
$successCount = 0
$failCount = 0
$warnCount = 0
$skipCount = 0
$reachableRepoCount = 0

foreach ($repo in $repositories) {
    Write-Log "Scanning: $($repo.Path)" -Color Yellow

    # -ErrorAction SilentlyContinue is load-bearing: on an unreadable UNC path
    # Test-Path RAISES "Access is denied" rather than returning $false, and the
    # script-wide $ErrorActionPreference = "Stop" turned that into a fatal error.
    # One unreachable repository then aborted the whole run before Phase 2, so
    # every OTHER machine — healthy ones included — silently stopped reporting.
    if (-not (Test-Path $repo.Path -ErrorAction SilentlyContinue)) {
        Write-Log "Repository not accessible: $($repo.Path)" -Level WARN -Color Yellow
        continue
    }
    $reachableRepoCount++

    # Build the list of machines to check for this repository, then run ONE
    # loop over that list below with the (unchanged) per-machine body — a
    # named (flat) repository IS one machine, since some Macrium destinations
    # write .mrimg files directly into the destination with no per-machine
    # subdirectory to enumerate or take a name from. An unnamed repository
    # keeps today's behaviour: each subdirectory is a machine.
    if ($repo.Machine) {
        $machines = @(@{ Path = $repo.Path; Name = $repo.Machine })
    }
    else {
        $machines = @(Get-ChildItem -Path $repo.Path -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { @{ Path = $_.FullName; Name = $null } })
    }

    foreach ($machine in $machines) {
        $health = Test-BackupHealth -Path $machine.Path `
            -MaxAgeHours $config.backupMaxAgeHours `
            -FilePattern $config.backupFilePattern `
            -SkipIfRunning $config.skipIfRunning `
            -RunningFilePattern $config.runningFilePattern `
            -MachineName $machine.Name `
            -DeleteErrorFiles $deleteErrorFiles `
            -ErrorFileMinAgeHours $errorFileMinAgeHours

        $slug = Get-CheckSlug -CompanyId $config.companyId -MachineName $health.MachineName

        if ($health.IsSkipped) {
            Write-Log "  [SKIP] $($health.MachineName): $($health.SkipReason)" -Level SKIP -Color DarkGray
            $skipCount++
            continue
        }

        # Macrium verify after error-file cleanup (v2.6.0): a deleted
        # .error_loading file means a backup was interrupted, so the image
        # set it belonged to gets verified. State survives across runs -
        # a verify over SMB can take hours and the monitor runs hourly.
        # See Update-ImageSetVerify above for the full state machine.
        $verify = @{ ForceFail = $false; FailMessage = ''; JustPassed = $false; ImageId = $null }
        if ($verifyAfterErrorCleanup) {
            $verify = Update-ImageSetVerify -StateDir $script:VerifyStateDir -Slug $slug -MachineName $health.MachineName `
                -MachinePath $machine.Path -DeletedErrorFilePaths $health.DeletedErrorFilePaths `
                -FilePattern $config.backupFilePattern -MrverifyPath $mrverifyPath -VerifyPassword $verifyPassword
        }

        # Build status message. Corruption and staleness are independent
        # conditions, so report both. Previously corruption short-circuited the
        # message and a genuine backup stoppage was indistinguishable from a
        # .error_loading alert for as long as the corruption persisted.
        $freshDetail = if ($health.IsFresh) {
            "Last backup: $($health.BackupAge)h ago ($($health.BackupCount) files within threshold)"
        }
        else {
            "No backups found within last $($config.backupMaxAgeHours) hours"
        }

        $statusDetail = if ($health.IsWarning) {
            "WARNING: $($health.ErrorFileCount) corrupted backup file(s) left on disk (.error_loading) - delete them; backups themselves are current: $freshDetail"
        }
        elseif ($health.HasErrorFiles) {
            "ERROR: $($health.ErrorFileCount) corrupted backup file(s) detected (.error_loading); $freshDetail"
        }
        else {
            $freshDetail
        }

        if ($health.DeletedErrorFileCount -gt 0) {
            $statusDetail = "removed $($health.DeletedErrorFileCount) leftover .error_loading file(s); $statusDetail"
        }

        if ($verify.JustPassed) {
            $statusDetail = "$statusDetail; Macrium verify passed for image set $($verify.ImageId)"
        }

        # IsStale marks the "no backup within threshold, but not corrupt,
        # not a server" case below - the one the v2.2.4 direct-ping skip
        # exists for. It's still added to $results so the coordinator can
        # judge it against Atera's online state; only the direct-to-HC
        # fallback (no coordinator) needs to keep skipping it - see Phase 2.
        $isStale = $false

        if ($verify.ForceFail) {
            # A past image set is known not to be restorable. This overrides
            # every other verdict below, including a fresh/uncorrupted backup:
            # a fresh backup that fails verification still isn't one we can
            # promise a restore from.
            Write-Log "  [ERR]  $($health.MachineName): $($verify.FailMessage)" -Level FAIL -Color Magenta
            $failCount++
            $statusDetail = "$($verify.FailMessage); $statusDetail"
        }
        elseif ($health.HasErrorFiles -and -not $health.IsFresh) {
            # Corrupt AND nothing fresh - the case the corruption check exists
            # for. Fails for every device type; the stale-workstation tolerance
            # below deliberately does not apply here.
            Write-Log "  [ERR]  $($health.MachineName): $statusDetail" -Level FAIL -Color Magenta
            $failCount++
        }
        elseif ($health.IsWarning) {
            Write-Log "  [WARN] $($health.MachineName): $statusDetail" -Level WARN -Color Yellow
            $warnCount++
        }
        elseif ($health.IsFresh) {
            Write-Log "  [OK]   $($health.MachineName): $statusDetail" -Level OK -Color Green
            $successCount++
        }
        else {
            # No backup within the threshold, but the machine is online and the
            # backups are not corrupt. Servers are expected to back up daily and
            # are latency-critical, so keep the explicit failure ping for them.
            # Workstations/notebooks (and non-standard names) legitimately go days
            # between images. Reported as unhealthy below so the coordinator can
            # weigh Atera's online/offline state (and, if online, an online-hours
            # budget) instead of the raw HC period - a machine switched off for
            # longer than its own HC period (nb 8d / wks 4d + grace) previously
            # alerted DOWN on elapsed calendar time alone, having missed nothing
            # (PR NB005, RAHR NB007, 2026-09-20). Without a coordinator, sending
            # an explicit /fail here still flips the HC check DOWN immediately
            # and defeats the check's own Period tolerance, flooding alerts - so
            # the direct-ping fallback in Phase 2 filters these back out.
            $devType = (Get-DeviceTypeSettings -MachineName $health.MachineName).Tag
            if ($devType -eq 'srv') {
                Write-Log "  [FAIL] $($health.MachineName): $statusDetail" -Level FAIL -Color Red
                $failCount++
            }
            else {
                Write-Log "  [SKIP] $($health.MachineName): $statusDetail (stale; deferring to HC period/coordinator)" -Level SKIP -Color DarkGray
                $skipCount++
                # The coordinator's online-hours budget only exists for wks/nb;
                # it would fail a stale non-standard name immediately, so those
                # keep the plain v2.2.4 skip.
                if ($devType -notin @('wks', 'nb')) { continue }
                $isStale = $true
            }
        }

        $results += @{
            MachineName = $health.MachineName
            Slug = $slug
            IsHealthy = if ($verify.ForceFail) { $false } else { $health.IsHealthy }
            IsStale = $isStale
            IsSkipped = $health.IsSkipped
            BackupAge = $health.BackupAge
            BackupCount = $health.BackupCount
            HasErrorFiles = $health.HasErrorFiles
            StatusMessage = "[BackupCheck v$($script:Version)] $statusDetail"
        }
    }
}

# Phase 1b: Air-gap media. Not freshness - restorability. The failure this
# exists for (RAHR, Feb-Aug 2026) was a medium that looked current by file
# dates while the newest chain had no base image and its copies had died
# mid-write, so nothing on it could be restored. A failed assertion is a
# FAIL for that machine, never a skip.
$airGapResults = @()
$airGapReachable = 0
foreach ($root in $airGapRoots) {
    Write-Log "Scanning air-gap medium: $root" -Color Yellow
    if (-not (Test-Path $root -ErrorAction SilentlyContinue)) {
        # Say WHY. "Not accessible" alone cannot tell a medium that was pulled
        # from one the account may not read, and those need opposite actions:
        # 2026-09-02 at RAHR both usbshares existed with the media attached and
        # the monitor account simply had no permission on them, which read as
        # "no disk" in the log.
        $reason = "path not found"
        try { Get-ChildItem $root -ErrorAction Stop | Out-Null }
        catch { $reason = $_.Exception.Message }
        Write-Log "Air-gap medium not accessible: $root ($reason)" -Level WARN -Color Yellow
        continue
    }
    $airGapReachable++

    # System/housekeeping folders a NAS puts on removable media are not
    # share copies (#recycle, @eaDir, $RECYCLE.BIN, System Volume Information).
    $shareCopies = @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^[#@$]' -and $_.Name -ne 'System Volume Information' })
    foreach ($shareCopy in $shareCopies) {
        $machineDirs = @(Get-ChildItem -Path $shareCopy.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^[#@$]' })
        foreach ($machineDir in $machineDirs) {
            $chain = Test-AirGapChain -Path $machineDir.FullName -MachineName $machineDir.Name
            $chain.Medium = "$root\$($shareCopy.Name)"
            switch ($chain.Status) {
                "OK"   { Write-Log "  [OK]   $($chain.MachineName): $($chain.Detail)" -Level OK -Color Green }
                "BUSY" { Write-Log "  [SKIP] $($chain.MachineName): $($chain.Detail)" -Level SKIP -Color DarkGray }
                default { Write-Log "  [FAIL] $($chain.MachineName): $($chain.Detail)" -Level FAIL -Color Red }
            }
            $airGapResults += $chain
        }
    }
}

# Phase 2: Report results - coordinator or direct HC pings
$useDirectPing = $true

if ($coordinatorUrl -and $coordinatorKey -and $results.Count -gt 0) {
    Write-Log "Sending results to coordinator ($coordinatorUrl)..."
    $coordSuccess = Send-CoordinatorReport `
        -CoordinatorUrl $coordinatorUrl `
        -ApiKey $coordinatorKey `
        -CompanyId $config.companyId `
        -MachineResults $results
    if ($coordSuccess) {
        $useDirectPing = $false
    }
}

if ($useDirectPing) {
    if ($coordinatorUrl) {
        Write-Log "Falling back to direct HC pings" -Level WARN -Color Yellow
    }

    # Stale wks/nb/non-standard results exist so a coordinator can weigh them
    # against Atera's online state - there is no such judgment call without
    # one, and pinging /fail directly here is the v2.2.4 flood (PR NB005,
    # RAHR NB007, 2026-09-20): an offline notebook simply running out its own
    # HC period. Filter them back out, exactly as the old pre-v2.6.0 `continue`
    # did, so the fallback path behaves exactly as it always has.
    $directResults = @($results | Where-Object { -not $_.IsStale })
    $suppressedCount = $results.Count - $directResults.Count
    if ($suppressedCount -gt 0) {
        Write-Log "  Suppressing $suppressedCount stale result(s) from direct ping (no coordinator to judge online state; deferring to HC period)" -Level SKIP -Color DarkGray
    }

    foreach ($r in $directResults) {
        $pingResult = Send-HealthCheck -BaseUrl $config.healthchecksBaseUrl `
            -PingKey $pingKey `
            -Slug $r.Slug `
            -Success $r.IsHealthy `
            -Message $r.StatusMessage `
            -Tags $tags `
            -ApiKey $apiKey `
            -MachineName $r.MachineName `
            -ConfigCache $configCache

        if (-not $pingResult.Success) {
            Write-Log "  Failed to send ping for $($r.MachineName): $($pingResult.Error)" -Level WARN -Color Yellow
        }
    }

    # Save HC API configuration cache (only used in direct ping mode)
    Save-ConfigCache -Cache $configCache
}

# Phase 3: Air-gap verdict -> ONE check, "{companyId}-usb-copy", pinged
# directly (the coordinator's Atera-online logic is about machines, not
# media). Every machine's line is in the ping body. No medium reachable ->
# no ping at all, so the check goes late instead of lying either way.
$airGapOk = 0
$airGapFail = 0
$airGapBusy = 0
if ($airGapRoots.Count -gt 0) {
    $airGapOk = @($airGapResults | Where-Object { $_.Status -eq "OK" }).Count
    $airGapFail = @($airGapResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $airGapBusy = @($airGapResults | Where-Object { $_.Status -eq "BUSY" }).Count
    $airGapSlug = Get-CheckSlug -CompanyId $config.companyId -MachineName "usb-copy"

    if ($airGapReachable -eq 0) {
        Write-Log "No air-gap medium reachable - not pinging $airGapSlug (check will go late)" -Level WARN -Color Yellow
    }
    else {
        $airGapSuccess = ($airGapFail -eq 0 -and $airGapResults.Count -gt 0)
        $airGapHeader = "[BackupCheck v$($script:Version)] Air-gap media: $airGapReachable of $($airGapRoots.Count) reachable, $($airGapResults.Count) machine(s): $airGapOk ok, $airGapFail fail, $airGapBusy in progress"
        if ($airGapResults.Count -eq 0) {
            $airGapHeader += " - FAIL: no image chain on any reachable medium"
        }
        $airGapLines = @($airGapResults | Sort-Object { $_.Status }, { $_.MachineName } | ForEach-Object {
            "$($_.Status.PadRight(4)) $($_.MachineName): $($_.Detail) [$($_.Medium)]"
        })
        $airGapMessage = (@($airGapHeader) + $airGapLines) -join "`n"

        $pingResult = Send-HealthCheck -BaseUrl $config.healthchecksBaseUrl `
            -PingKey $pingKey `
            -Slug $airGapSlug `
            -Success $airGapSuccess `
            -Message $airGapMessage `
            -Tags ($tags + "usbcopy") `
            -ApiKey $apiKey `
            -MachineName "usb-copy" `
            -ConfigCache $configCache
        if ($pingResult.Success) {
            Write-Log "Air-gap ping sent ($airGapSlug, $(if ($airGapSuccess) { 'success' } else { 'FAIL' }))" -Level $(if ($airGapSuccess) { "OK" } else { "FAIL" }) -Color $(if ($airGapSuccess) { "Green" } else { "Red" })
        }
        else {
            Write-Log "Failed to send air-gap ping ($airGapSlug): $($pingResult.Error)" -Level WARN -Color Yellow
        }
        Save-ConfigCache -Cache $configCache
    }
}

# Summary
Write-Log ""
Write-Log "Summary" -Color Cyan
Write-Log "-------" -Color Cyan
Write-Log "  Healthy:  $successCount" -Level OK -Color Green
Write-Log "  Warnings: $warnCount" -Level $(if ($warnCount -gt 0) { "WARN" } else { "INFO" }) -Color $(if ($warnCount -gt 0) { "Yellow" } else { "Gray" })
Write-Log "  Failed:   $failCount" -Level $(if ($failCount -gt 0) { "FAIL" } else { "INFO" }) -Color $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Log "  Skipped:  $skipCount" -Level INFO
if ($airGapRoots.Count -gt 0) {
    Write-Log "  Air-gap:  $airGapOk ok, $airGapFail fail, $airGapBusy in progress ($airGapReachable of $($airGapRoots.Count) media reachable)" -Level $(if ($airGapFail -gt 0) { "FAIL" } else { "INFO" }) -Color $(if ($airGapFail -gt 0) { "Red" } else { "Gray" })
}

# Meta-monitoring: ping a health check for the monitor itself.
#
# A run that could reach NONE of its configured repositories has checked
# nothing, and must not say otherwise. On 2026-09-02 RAHR's NAS stayed off
# after a site outage; the monitor logged "Repository not accessible" twice,
# reported 0/0/0 and pinged the meta check healthy every hour, so a dead NAS
# raised no alert until the per-machine checks expired a day and a half
# later. Now that run pings /fail with the reason in the body.
$metaSlug = "$($config.companyId)-monitor-health".ToLower()
$noRepoReachable = ($repositories.Count -gt 0 -and $reachableRepoCount -eq 0)
if ($noRepoReachable) {
    $metaMessage = "[BackupCheck v$($script:Version)] FAILED: 0 of $($repositories.Count) configured repositories reachable - nothing was checked ($(($repositories | ForEach-Object { $_.Path }) -join ', '))"
    Write-Log "No configured repository reachable - reporting the monitor FAILED" -Level FAIL -Color Red
}
else {
    $metaMessage = "[BackupCheck v$($script:Version)] Completed: $successCount ok, $warnCount warn, $failCount fail, $skipCount skip ($reachableRepoCount of $($repositories.Count) repositories reachable)"
}
try {
    $metaEndpoint = "$($config.healthchecksBaseUrl)/$pingKey/$metaSlug"
    if ($noRepoReachable) { $metaEndpoint += "/fail" }
    $metaEndpoint += "?create=1"
    Invoke-WebRequest -Uri $metaEndpoint -Method POST -Body $metaMessage -ContentType "text/plain" -UseBasicParsing | Out-Null
    Write-Log "Meta-monitoring ping sent ($metaSlug$(if ($noRepoReachable) { ', /fail' }))" -Level $(if ($noRepoReachable) { "FAIL" } else { "OK" }) -Color $(if ($noRepoReachable) { "Red" } else { "Green" })
}
catch {
    Write-Log "Meta-monitoring ping failed: $_" -Level WARN -Color Yellow
}

# Cleanup: disconnect any shares we mounted
if ($script:MountedShares.Count -gt 0) {
    Disconnect-MountedShares
}

} catch {
    Write-Log "Script failed: $_" -Level ERROR -Color Red
    exit 1
}

if ($failCount -gt 0 -or $airGapFail -gt 0 -or $noRepoReachable) {
    exit 1
}

exit 0

#endregion
