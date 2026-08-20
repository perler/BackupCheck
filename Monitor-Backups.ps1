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

.NOTES
    Version: 2.3.0
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
$script:Version = "2.4.0"

# Track connections we've made for cleanup
$script:MountedShares = @()

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
        [string]$MachineName
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

# Load HC API configuration cache
$configCache = Get-ConfigCache

# Connect to shares if credentials are provided
$repoUsername = $envVars["REPO_USERNAME"]
$repoPassword = $envVars["REPO_PASSWORD"]

try {
if ($repoUsername -and $repoPassword) {
    Write-Log "Connecting to repositories with stored credentials..."
    $uniqueServers = @{}
    foreach ($repo in $repositories) {
        $repoPath = $repo.Path

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
            -MachineName $machine.Name

        $slug = Get-CheckSlug -CompanyId $config.companyId -MachineName $health.MachineName

        if ($health.IsSkipped) {
            Write-Log "  [SKIP] $($health.MachineName): $($health.SkipReason)" -Level SKIP -Color DarkGray
            $skipCount++
            continue
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

        if ($health.HasErrorFiles -and -not $health.IsFresh) {
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
            # between images; an explicit /fail here flips the HC check DOWN
            # immediately and defeats the check's own Period tolerance
            # (wks 4d / nb 8d + grace), flooding alerts. Skip instead and let the
            # HC Period+grace raise the alarm if backups genuinely stop.
            $devType = (Get-DeviceTypeSettings -MachineName $health.MachineName).Tag
            if ($devType -eq 'srv') {
                Write-Log "  [FAIL] $($health.MachineName): $statusDetail" -Level FAIL -Color Red
                $failCount++
            }
            else {
                Write-Log "  [SKIP] $($health.MachineName): $statusDetail (stale; deferring to HC period)" -Level SKIP -Color DarkGray
                $skipCount++
                continue
            }
        }

        $results += @{
            MachineName = $health.MachineName
            Slug = $slug
            IsHealthy = $health.IsHealthy
            IsSkipped = $health.IsSkipped
            BackupAge = $health.BackupAge
            BackupCount = $health.BackupCount
            HasErrorFiles = $health.HasErrorFiles
            StatusMessage = "[BackupCheck v$($script:Version)] $statusDetail"
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

    foreach ($r in $results) {
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

# Summary
Write-Log ""
Write-Log "Summary" -Color Cyan
Write-Log "-------" -Color Cyan
Write-Log "  Healthy:  $successCount" -Level OK -Color Green
Write-Log "  Warnings: $warnCount" -Level $(if ($warnCount -gt 0) { "WARN" } else { "INFO" }) -Color $(if ($warnCount -gt 0) { "Yellow" } else { "Gray" })
Write-Log "  Failed:   $failCount" -Level $(if ($failCount -gt 0) { "FAIL" } else { "INFO" }) -Color $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Log "  Skipped:  $skipCount" -Level INFO

# Meta-monitoring: ping a health check for the monitor itself
$metaSlug = "$($config.companyId)-monitor-health".ToLower()
$metaMessage = "[BackupCheck v$($script:Version)] Completed: $successCount ok, $warnCount warn, $failCount fail, $skipCount skip"
try {
    $metaEndpoint = "$($config.healthchecksBaseUrl)/$pingKey/$metaSlug`?create=1"
    Invoke-WebRequest -Uri $metaEndpoint -Method POST -Body $metaMessage -ContentType "text/plain" -UseBasicParsing | Out-Null
    Write-Log "Meta-monitoring ping sent ($metaSlug)" -Level OK -Color Green
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

if ($failCount -gt 0) {
    exit 1
}

exit 0

#endregion
