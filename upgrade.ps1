<#
.SYNOPSIS
    Upgrades BackupCheck to the latest version from GitHub.

.DESCRIPTION
    Downloads the latest release, verifies SHA256 checksums, backs up current
    files, and extracts new ones. Preserves config.json and .env.

    Run with:
      irm https://raw.githubusercontent.com/perler/BackupCheck/master/upgrade.ps1 | iex

    Or from an existing installation:
      .\upgrade.ps1

    Optional: pass -CoordinatorUrl and -CoordinatorApiKey to configure the
    coordinator (v2.1+).

.NOTES
    Requires: PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallDir,

    [Parameter()]
    [string]$CoordinatorUrl,

    [Parameter()]
    [string]$CoordinatorApiKey
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoBase = "https://raw.githubusercontent.com/perler/BackupCheck/master"

# Determine install directory
if (-not $InstallDir) {
    # Check common locations
    $candidates = @(
        $PSScriptRoot,
        (Join-Path $env:ProgramData "BackupCheck"),
        "C:\BackupCheck"
    )
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path (Join-Path $dir "Monitor-Backups.ps1") -ErrorAction SilentlyContinue)) {
            $InstallDir = $dir
            break
        }
    }
    if (-not $InstallDir) {
        $InstallDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\BackupCheck" }
    }
}

Write-Host ""
Write-Host "BackupCheck Upgrade" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor Cyan
Write-Host "Install directory: $InstallDir"
Write-Host ""

# Get current version
$currentVersion = "unknown"
$monitorPath = Join-Path $InstallDir "Monitor-Backups.ps1"
if (Test-Path $monitorPath) {
    $content = Get-Content $monitorPath -Raw
    if ($content -match '\$script:Version\s*=\s*"([^"]+)"') {
        $currentVersion = $Matches[1]
    }
    elseif ($content -match 'Version:\s*(\S+)') {
        $currentVersion = $Matches[1]
    }
}
Write-Host "Current version: $currentVersion" -ForegroundColor Gray

# Fetch latest.json
Write-Host "Checking for latest version..." -ForegroundColor Gray
try {
    $latest = Invoke-RestMethod -Uri "$RepoBase/latest.json" -TimeoutSec 10
}
catch {
    Write-Host "ERROR: Could not fetch version info from GitHub: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Latest version:  $($latest.version)" -ForegroundColor Gray
Write-Host ""

if ($currentVersion -eq $latest.version) {
    Write-Host "Already up to date!" -ForegroundColor Green
    exit 0
}

# Download the release zip
$zipUrl = $latest.releaseUrl
$zipPath = Join-Path $env:TEMP "BackupCheck-upgrade.zip"
$extractPath = Join-Path $env:TEMP "BackupCheck-upgrade"

Write-Host "Downloading $zipUrl ..." -ForegroundColor Gray
try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
}
catch {
    Write-Host "ERROR: Download failed: $_" -ForegroundColor Red
    exit 1
}

# Extract
if (Test-Path $extractPath) {
    Remove-Item $extractPath -Recurse -Force
}
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

# Verify SHA256 checksums
Write-Host "Verifying checksums..." -ForegroundColor Gray
$allValid = $true
foreach ($fileEntry in $latest.files.PSObject.Properties) {
    $fileName = $fileEntry.Name
    $expectedHash = $fileEntry.Value.sha256
    $filePath = Join-Path $extractPath $fileName

    if (-not (Test-Path $filePath)) {
        Write-Host "  MISSING: $fileName" -ForegroundColor Red
        $allValid = $false
        continue
    }

    $actualHash = (Get-FileHash -Path $filePath -Algorithm SHA256).Hash.ToLower()
    if ($actualHash -ne $expectedHash.ToLower()) {
        Write-Host "  MISMATCH: $fileName" -ForegroundColor Red
        Write-Host "    Expected: $expectedHash" -ForegroundColor Red
        Write-Host "    Got:      $actualHash" -ForegroundColor Red
        $allValid = $false
    }
    else {
        Write-Host "  OK: $fileName" -ForegroundColor Green
    }
}

if (-not $allValid) {
    Write-Host ""
    Write-Host "ERROR: Checksum verification failed. Aborting upgrade." -ForegroundColor Red
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# Create install directory if needed
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host "Created directory: $InstallDir" -ForegroundColor Gray
}

# Backup and copy files
Write-Host ""
Write-Host "Installing..." -ForegroundColor Gray
$filesToCopy = Get-ChildItem -Path $extractPath -File
foreach ($file in $filesToCopy) {
    $destPath = Join-Path $InstallDir $file.Name

    # Skip config files - never overwrite
    if ($file.Name -eq "config.json" -or $file.Name -eq ".env") {
        continue
    }

    # Backup existing file
    if (Test-Path $destPath) {
        $bakPath = "$destPath.bak"
        Copy-Item -Path $destPath -Destination $bakPath -Force
        Write-Host "  Backed up: $($file.Name) -> $($file.Name).bak" -ForegroundColor DarkGray
    }

    Copy-Item -Path $file.FullName -Destination $destPath -Force
    Write-Host "  Updated:   $($file.Name)" -ForegroundColor Green
}

# Add coordinator config to .env if provided
$envPath = Join-Path $InstallDir ".env"
if ($CoordinatorUrl -or $CoordinatorApiKey) {
    if (Test-Path $envPath) {
        $envContent = Get-Content $envPath -Raw
        if ($CoordinatorUrl -and $envContent -notmatch "COORDINATOR_URL") {
            Add-Content -Path $envPath -Value "COORDINATOR_URL=$CoordinatorUrl"
            Write-Host "  Added COORDINATOR_URL to .env" -ForegroundColor Green
        }
        if ($CoordinatorApiKey -and $envContent -notmatch "COORDINATOR_API_KEY") {
            Add-Content -Path $envPath -Value "COORDINATOR_API_KEY=$CoordinatorApiKey"
            Write-Host "  Added COORDINATOR_API_KEY to .env" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  WARNING: .env not found - run Install-BackupMonitor.ps1 first" -ForegroundColor Yellow
    }
}

# Cleanup temp files
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

# Done
Write-Host ""
Write-Host "Upgraded: $currentVersion -> $($latest.version)" -ForegroundColor Green
Write-Host ""
if (-not $CoordinatorUrl) {
    Write-Host "To enable the coordinator (v2.1+), re-run with:" -ForegroundColor Gray
    Write-Host "  .\upgrade.ps1 -CoordinatorUrl 'https://backupcheck.patsplanet.com/api/report' -CoordinatorApiKey 'YOUR_KEY'" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "The next scheduled run will use the new version." -ForegroundColor Gray
