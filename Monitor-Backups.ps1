<#
.SYNOPSIS
    Monitors Macrium Reflect backup repositories and reports status to healthchecks.io.

.DESCRIPTION
    This script scans configured backup repositories for recent .mrimg backup files.
    For each machine directory found, it checks if a backup was completed within the
    configured time window and reports the status to healthchecks.io.

.NOTES
    Version: 0.3.0
    Requires: PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,

    [Parameter()]
    [string]$EnvPath
)

$ErrorActionPreference = "Stop"

# Force TLS 1.2 for all HTTPS connections (required by healthchecks.io)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Determine script directory (handles both direct execution and -File invocation)
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ScriptDir) { $ScriptDir = Get-Location }

# Set default paths if not provided
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir "config.json" }
if (-not $EnvPath) { $EnvPath = Join-Path $ScriptDir ".env" }

#region Functions

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
                Write-Verbose "Auto-detecting repositories via mrserver.exe..."
                $output = & $mrserverPath --action get-repo-status --outputtoconsole 2>&1
                # mrserver outputs CSV format
                $repoData = $output | ConvertFrom-Csv

                foreach ($repo in $repoData) {
                    $repoPath = $repo."Repository Path"
                    if ($repoPath -and (Test-Path $repoPath -ErrorAction SilentlyContinue)) {
                        $repositories += $repoPath
                    }
                }

                if ($repositories.Count -gt 0) {
                    Write-Verbose "Auto-detected $($repositories.Count) repositories"
                    return $repositories
                }
            }
            catch {
                Write-Warning "Auto-detection failed: $_"
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

    # Find backup files
    $cutoffTime = (Get-Date).AddHours(-$MaxAgeHours)
    $backupFiles = Get-ChildItem -Path $Path -Filter $FilePattern -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cutoffTime }

    $result.BackupCount = ($backupFiles | Measure-Object).Count

    if ($result.BackupCount -gt 0) {
        $latestFile = $backupFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $result.LatestBackup = $latestFile.FullName
        $result.BackupAge = [math]::Round(((Get-Date) - $latestFile.LastWriteTime).TotalHours, 1)
        $result.IsHealthy = $true
    }

    return $result
}

function Send-HealthCheck {
    <#
    .SYNOPSIS
        Sends a ping to healthchecks.io.
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
        [string[]]$Tags = @()
    )

    $endpoint = if ($Success) {
        "$BaseUrl/$PingKey/$Slug"
    }
    else {
        "$BaseUrl/$PingKey/$Slug/fail"
    }

    # Add auto-provisioning parameter
    $endpoint += "?create=1"

    # Add tags if provided
    if ($Tags.Count -gt 0) {
        $tagsParam = ($Tags | ForEach-Object { [Uri]::EscapeDataString($_) }) -join " "
        $endpoint += "&tags=$tagsParam"
    }

    try {
        $params = @{
            Uri = $endpoint
            Method = "POST"
            Body = $Message
            ContentType = "text/plain"
            UseBasicParsing = $true
        }

        $response = Invoke-WebRequest @params
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

#endregion

#region Main

Write-Host "BackupCheck Monitor v0.3.0" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Load configuration
Write-Host "Loading configuration..." -ForegroundColor Gray
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath. Run Install-BackupMonitor.ps1 first."
}

$config = Get-Content $ConfigPath | ConvertFrom-Json

# Load environment variables
$envVars = Get-EnvFile -Path $EnvPath
$pingKey = $envVars["HC_PING_KEY"]

if (-not $pingKey) {
    throw "HC_PING_KEY not found in $EnvPath"
}

Write-Host "Company ID: $($config.companyId)" -ForegroundColor Gray
Write-Host "Max backup age: $($config.backupMaxAgeHours) hours" -ForegroundColor Gray

# Build tags list: automatic tags + custom tags from config
$tags = @("backup", "macrium", $config.companyId.ToLower())
if ($config.tags -and $config.tags.Count -gt 0) {
    $tags += $config.tags
}
Write-Host "Tags: $($tags -join ', ')" -ForegroundColor Gray
Write-Host ""

# Get repositories
$repositories = Get-BackupRepositories -Config $config
Write-Host "Monitoring $($repositories.Count) repository(ies):" -ForegroundColor Gray
$repositories | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

# Process each repository
$results = @()
$successCount = 0
$failCount = 0
$skipCount = 0

foreach ($repo in $repositories) {
    Write-Host "Scanning: $repo" -ForegroundColor Yellow

    if (-not (Test-Path $repo)) {
        Write-Warning "Repository not accessible: $repo"
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
            Write-Host "  [SKIP] $($health.MachineName): $($health.SkipReason)" -ForegroundColor DarkGray
            $skipCount++
            continue
        }

        # Build status message
        $statusMessage = if ($health.IsHealthy) {
            "Last backup: $($health.BackupAge)h ago ($($health.BackupCount) files within threshold)"
        }
        else {
            "No backups found within last $($config.backupMaxAgeHours) hours"
        }

        # Send health check
        $pingResult = Send-HealthCheck -BaseUrl $config.healthchecksBaseUrl `
            -PingKey $pingKey `
            -Slug $slug `
            -Success $health.IsHealthy `
            -Message $statusMessage `
            -Tags $tags

        if ($health.IsHealthy) {
            Write-Host "  [OK]   $($health.MachineName): $statusMessage" -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "  [FAIL] $($health.MachineName): $statusMessage" -ForegroundColor Red
            $failCount++
        }

        if (-not $pingResult.Success) {
            Write-Warning "    Failed to send ping: $($pingResult.Error)"
        }

        $results += @{
            MachineName = $health.MachineName
            Slug = $slug
            IsHealthy = $health.IsHealthy
            IsSkipped = $health.IsSkipped
            BackupAge = $health.BackupAge
            PingSuccess = $pingResult.Success
        }
    }
}

# Summary
Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "-------" -ForegroundColor Cyan
Write-Host "  Healthy:  $successCount" -ForegroundColor Green
Write-Host "  Failed:   $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Host "  Skipped:  $skipCount" -ForegroundColor Gray
Write-Host ""

if ($failCount -gt 0) {
    exit 1
}

exit 0

#endregion
