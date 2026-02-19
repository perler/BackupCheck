<#
.SYNOPSIS
    Monitors Macrium Reflect backup repositories and reports status to healthchecks.io.

.DESCRIPTION
    This script scans configured backup repositories for recent .mrimg backup files.
    For each machine directory found, it checks if a backup was completed within the
    configured time window and reports the status to healthchecks.io.

    v2.0 adds: self-updating, HC API caching, structured logging, meta-monitoring.
    v2.1 adds: coordinator API integration with direct-ping fallback.

.NOTES
    Version: 2.1.0
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
$script:Version = "2.1.0"

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
                    return $repositories
                }
            }
            catch {
                Write-Log "Auto-detection failed: $_" -Level WARN -Color Yellow
            }
        }
    }

    # Fall back to configured repositories
    if ($Config.repositories -and $Config.repositories.Count -gt 0) {
        return $Config.repositories
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
        [string]$RunningFilePattern = "backup_running*"
    )

    $result = @{
        Path = $Path
        MachineName = Split-Path $Path -Leaf
        IsHealthy = $false
        IsSkipped = $false
        SkipReason = $null
        LatestBackup = $null
        BackupAge = $null
        BackupCount = 0
        HasErrorFiles = $false
        ErrorFileCount = 0
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

    # Check for error files (.mrimg.error_loading) - these indicate corruption
    $errorFiles = Get-ChildItem -Path $Path -Filter "*.error_loading" -Recurse -File -ErrorAction SilentlyContinue
    if ($errorFiles) {
        $result.HasErrorFiles = $true
        $result.ErrorFileCount = ($errorFiles | Measure-Object).Count
    }

    # Find backup files (exclude .error_loading and other non-backup extensions)
    $cutoffTime = (Get-Date).AddHours(-$MaxAgeHours)
    $backupFiles = Get-ChildItem -Path $Path -Filter $FilePattern -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -gt $cutoffTime -and
            $_.Name -notmatch '\.(error_loading|tmp)$'
        }

    $result.BackupCount = ($backupFiles | Measure-Object).Count

    if ($result.BackupCount -gt 0 -and -not $result.HasErrorFiles) {
        $latestFile = $backupFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $result.LatestBackup = $latestFile.FullName
        $result.BackupAge = [math]::Round(((Get-Date) - $latestFile.LastWriteTime).TotalHours, 1)
        $result.IsHealthy = $true
    }

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
        Checks GitHub for a newer version of BackupCheck.
    .OUTPUTS
        Returns update info hashtable if update available, $null otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl
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

    try {
        Write-Log "Checking for updates..."
        $latestJson = Invoke-RestMethod -Uri "$RepoUrl/latest.json" -TimeoutSec 10 -UseBasicParsing
        $remoteVersion = [version]$latestJson.version
        $localVersion = [version]$script:Version

        if ($remoteVersion -gt $localVersion) {
            Write-Log "Update available: v$($script:Version) -> v$($latestJson.version)" -Level INFO -Color Cyan
            return $latestJson
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
        $UpdateInfo
    )

    $releaseUrl = $UpdateInfo.releaseUrl
    if (-not $releaseUrl) {
        Write-Log "No release URL in update info" -Level WARN -Color Yellow
        return $false
    }

    $zipPath = Join-Path $env:TEMP "BackupCheck-update.zip"
    $extractPath = Join-Path $env:TEMP "BackupCheck-update"

    try {
        # Download the release zip
        Write-Log "Downloading update from $releaseUrl..."
        Invoke-WebRequest -Uri $releaseUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60

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

# Self-update check
if (-not $SkipUpdateCheck) {
    $updateRepoUrl = if ($config.updateUrl) {
        $config.updateUrl
    }
    else {
        "https://raw.githubusercontent.com/perler/BackupCheck/master"
    }

    $updateInfo = Test-UpdateAvailable -RepoUrl $updateRepoUrl
    if ($updateInfo) {
        $updated = Invoke-SelfUpdate -UpdateInfo $updateInfo
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
$repositories | ForEach-Object { Write-Log "  - $_" }

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
        if (-not $uniqueServers.ContainsKey($repo)) {
            $connected = Connect-ShareWithCredentials -SharePath $repo -Username $repoUsername -Password $repoPassword
            if ($connected) {
                Write-Log "  Connected: $repo" -Level OK -Color Green
            }
            else {
                Write-Log "  Failed: $repo" -Level FAIL -Color Red
            }
            if ($repo -match '^(\\\\[^\\]+)') {
                $uniqueServers[$Matches[1]] = $true
            }
        }
    }
}

# Phase 1: Scan all repositories and collect results
$results = @()
$successCount = 0
$failCount = 0
$skipCount = 0

foreach ($repo in $repositories) {
    Write-Log "Scanning: $repo" -Color Yellow

    if (-not (Test-Path $repo)) {
        Write-Log "Repository not accessible: $repo" -Level WARN -Color Yellow
        continue
    }

    # Get machine directories
    $machineDirs = Get-ChildItem -Path $repo -Directory -ErrorAction SilentlyContinue

    foreach ($machineDir in $machineDirs) {
        $health = Test-BackupHealth -Path $machineDir.FullName `
            -MaxAgeHours $config.backupMaxAgeHours `
            -FilePattern $config.backupFilePattern `
            -SkipIfRunning $config.skipIfRunning `
            -RunningFilePattern $config.runningFilePattern

        $slug = Get-CheckSlug -CompanyId $config.companyId -MachineName $health.MachineName

        if ($health.IsSkipped) {
            Write-Log "  [SKIP] $($health.MachineName): $($health.SkipReason)" -Level SKIP -Color DarkGray
            $skipCount++
            continue
        }

        # Build status message
        $statusDetail = if ($health.HasErrorFiles) {
            "ERROR: $($health.ErrorFileCount) corrupted backup file(s) detected (.error_loading)"
        }
        elseif ($health.IsHealthy) {
            "Last backup: $($health.BackupAge)h ago ($($health.BackupCount) files within threshold)"
        }
        else {
            "No backups found within last $($config.backupMaxAgeHours) hours"
        }

        if ($health.HasErrorFiles) {
            Write-Log "  [ERR]  $($health.MachineName): $statusDetail" -Level FAIL -Color Magenta
            $failCount++
        }
        elseif ($health.IsHealthy) {
            Write-Log "  [OK]   $($health.MachineName): $statusDetail" -Level OK -Color Green
            $successCount++
        }
        else {
            Write-Log "  [FAIL] $($health.MachineName): $statusDetail" -Level FAIL -Color Red
            $failCount++
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
$coordinatorUrl = if ($config.coordinatorUrl) { $config.coordinatorUrl } else { $envVars["COORDINATOR_URL"] }
$coordinatorKey = if ($config.coordinatorApiKey) { $config.coordinatorApiKey } else { $envVars["COORDINATOR_API_KEY"] }
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
Write-Log "  Failed:   $failCount" -Level $(if ($failCount -gt 0) { "FAIL" } else { "INFO" }) -Color $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Log "  Skipped:  $skipCount" -Level INFO

# Meta-monitoring: ping a health check for the monitor itself
$metaSlug = "$($config.companyId)-monitor-health".ToLower()
$metaMessage = "[BackupCheck v$($script:Version)] Completed: $successCount ok, $failCount fail, $skipCount skip"
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
