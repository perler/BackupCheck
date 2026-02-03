<#
.SYNOPSIS
    Installs and configures the BackupCheck monitoring solution.

.DESCRIPTION
    This script guides you through setting up the backup monitoring solution:
    - Prompts for Company ID and healthchecks.io ping key
    - Auto-detects Macrium Reflect backup repositories
    - Validates repository access with provided credentials
    - Creates configuration files
    - Sets up a Windows Scheduled Task to run hourly

.NOTES
    Version: 0.1.0
    Requires: PowerShell 5.1+, Administrator privileges
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

#region Configuration

# Determine script directory (handles both direct execution and -File invocation)
$ScriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ScriptPath) { $ScriptPath = Get-Location }

$ConfigPath = Join-Path $ScriptPath "config.json"
$EnvPath = Join-Path $ScriptPath ".env"
$MonitorScript = Join-Path $ScriptPath "Monitor-Backups.ps1"
$TaskName = "BackupMonitor"

#endregion

#region Functions

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "=== $Text ===" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([int]$Number, [string]$Text)
    Write-Host "[$Number] $Text" -ForegroundColor Yellow
}

function Get-UserInput {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required,
        [switch]$IsSecure
    )

    $displayPrompt = if ($Default) { "$Prompt [$Default]" } else { $Prompt }

    do {
        if ($IsSecure) {
            $secureInput = Read-Host "$displayPrompt" -AsSecureString
            $input = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
            )
        }
        else {
            $input = Read-Host "$displayPrompt"
        }

        if ([string]::IsNullOrWhiteSpace($input) -and $Default) {
            $input = $Default
        }

        if ($Required -and [string]::IsNullOrWhiteSpace($input)) {
            Write-Host "This field is required." -ForegroundColor Red
        }
    } while ($Required -and [string]::IsNullOrWhiteSpace($input))

    return $input
}

function Get-MacriumRepositories {
    <#
    .SYNOPSIS
        Auto-detects Macrium Reflect repositories using mrserver.exe.
    #>
    $mrserverPath = "C:\Program Files\Macrium\SiteManager\mrserver.exe"

    if (-not (Test-Path $mrserverPath)) {
        Write-Warning "Macrium Site Manager not found at: $mrserverPath"
        return @()
    }

    try {
        Write-Host "Detecting repositories via Macrium Site Manager..." -ForegroundColor Gray
        $output = & $mrserverPath --action get-repo-status --outputtoconsole 2>&1
        # mrserver outputs CSV format
        $repoData = $output | ConvertFrom-Csv

        $repositories = @()
        foreach ($repo in $repoData) {
            $repoPath = $repo."Repository Path"
            if ($repoPath) {
                $repositories += $repoPath
            }
        }

        return $repositories
    }
    catch {
        Write-Warning "Failed to auto-detect repositories: $_"
        return @()
    }
}

function Test-RepositoryAccess {
    <#
    .SYNOPSIS
        Tests if the provided credentials can access a repository path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    # For UNC paths, we need to test access with credentials
    if ($Path -match "^\\\\") {
        try {
            # Create a PSDrive to test access
            $driveName = "BackupTest_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
            $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $Path -Credential $Credential -ErrorAction Stop
            Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
            return $true
        }
        catch {
            return $false
        }
    }
    else {
        # Local path - just test existence
        return Test-Path $Path -ErrorAction SilentlyContinue
    }
}

function Test-HealthChecksConnection {
    <#
    .SYNOPSIS
        Tests connectivity to healthchecks.io.
    #>
    param(
        [string]$PingKey
    )

    try {
        # Just test that we can reach the service
        $response = Invoke-WebRequest -Uri "https://hc-ping.com/$PingKey/test-connection?create=1" -Method POST -UseBasicParsing -TimeoutSec 10
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

#endregion

#region Main

Clear-Host
Write-Host ""
Write-Host "  ____             _                  ____ _               _    " -ForegroundColor Cyan
Write-Host " | __ )  __ _  ___| | ___   _ _ __   / ___| |__   ___  ___| | __" -ForegroundColor Cyan
Write-Host " |  _ \ / _` |/ __| |/ / | | | '_ \ | |   | '_ \ / _ \/ __| |/ /" -ForegroundColor Cyan
Write-Host " | |_) | (_| | (__|   <| |_| | |_) || |___| | | |  __/ (__|   < " -ForegroundColor Cyan
Write-Host " |____/ \__,_|\___|_|\_\\__,_| .__/  \____|_| |_|\___|\___|_|\_\" -ForegroundColor Cyan
Write-Host "                             |_|                               " -ForegroundColor Cyan
Write-Host ""
Write-Host "  Backup Monitoring Installer v0.1.0" -ForegroundColor Gray
Write-Host ""

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Running without Administrator privileges." -ForegroundColor Yellow
    Write-Host "         Scheduled task creation may fail." -ForegroundColor Yellow
    Write-Host ""
}

# Check for existing installation
if ((Test-Path $ConfigPath) -and -not $Force) {
    Write-Host "Existing configuration found at: $ConfigPath" -ForegroundColor Yellow
    $overwrite = Get-UserInput -Prompt "Overwrite existing configuration? (y/N)"
    if ($overwrite -ne "y" -and $overwrite -ne "Y") {
        Write-Host "Installation cancelled." -ForegroundColor Gray
        exit 0
    }
}

# Step 1: Company ID
Write-Header "Step 1: Company Configuration"
Write-Host "The Company ID is used as a prefix for all health check names." -ForegroundColor Gray
Write-Host "Example: If Company ID is 'LTHX', checks will be named 'lthx-wks001', 'lthx-srv003', etc." -ForegroundColor Gray
Write-Host ""

$companyId = Get-UserInput -Prompt "Enter Company ID (e.g., LTHX)" -Required
$companyId = $companyId.ToUpper()

# Step 2: healthchecks.io Configuration
Write-Header "Step 2: healthchecks.io Configuration"
Write-Host "You need a Ping Key from your healthchecks.io project." -ForegroundColor Gray
Write-Host "Find it at: Project Settings > Ping Key" -ForegroundColor Gray
Write-Host ""

$pingKey = Get-UserInput -Prompt "Enter healthchecks.io Ping Key" -Required

Write-Host ""
Write-Host "Testing healthchecks.io connection..." -ForegroundColor Gray
if (Test-HealthChecksConnection -PingKey $pingKey) {
    Write-Host "  Connection successful!" -ForegroundColor Green
}
else {
    Write-Host "  WARNING: Could not verify connection to healthchecks.io" -ForegroundColor Yellow
    Write-Host "  The ping key may be invalid or there may be network issues." -ForegroundColor Yellow
    $continue = Get-UserInput -Prompt "Continue anyway? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "Installation cancelled." -ForegroundColor Gray
        exit 1
    }
}

# Step 3: Repository Detection
Write-Header "Step 3: Repository Detection"

$repositories = Get-MacriumRepositories

if ($repositories.Count -gt 0) {
    Write-Host "Detected $($repositories.Count) repository(ies):" -ForegroundColor Green
    $repositories | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    Write-Host ""

    $useDetected = Get-UserInput -Prompt "Use these repositories? (Y/n)" -Default "Y"
    if ($useDetected -eq "n" -or $useDetected -eq "N") {
        $repositories = @()
    }
}

if ($repositories.Count -eq 0) {
    Write-Host "Enter repository paths (one per line, empty line to finish):" -ForegroundColor Gray
    $repositories = @()
    do {
        $repo = Get-UserInput -Prompt "Repository path"
        if ($repo) {
            $repositories += $repo
        }
    } while ($repo)
}

if ($repositories.Count -eq 0) {
    Write-Host "ERROR: At least one repository is required." -ForegroundColor Red
    exit 1
}

# Step 4: Credentials for Scheduled Task
Write-Header "Step 4: Scheduled Task Credentials"
Write-Host "The scheduled task needs to run as a user with access to the backup repositories." -ForegroundColor Gray
Write-Host "This is typically a domain account or local account with network share access." -ForegroundColor Gray
Write-Host ""

$username = Get-UserInput -Prompt "Username (DOMAIN\user or user@domain.com)" -Required
$password = Get-UserInput -Prompt "Password" -Required -IsSecure

# Create credential object
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

# Step 5: Validate Repository Access
Write-Header "Step 5: Validating Repository Access"

$accessFailed = @()
foreach ($repo in $repositories) {
    Write-Host "  Testing: $repo ... " -NoNewline -ForegroundColor Gray

    if (Test-RepositoryAccess -Path $repo -Credential $credential) {
        Write-Host "OK" -ForegroundColor Green
    }
    else {
        Write-Host "FAILED" -ForegroundColor Red
        $accessFailed += $repo
    }
}

if ($accessFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: Could not access the following repositories:" -ForegroundColor Red
    $accessFailed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Please verify:" -ForegroundColor Yellow
    Write-Host "  1. The paths are correct" -ForegroundColor Yellow
    Write-Host "  2. The credentials have read access to these shares" -ForegroundColor Yellow
    Write-Host "  3. The network shares are online" -ForegroundColor Yellow
    Write-Host ""

    $continue = Get-UserInput -Prompt "Continue with accessible repositories only? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "Installation cancelled." -ForegroundColor Gray
        exit 1
    }

    $repositories = $repositories | Where-Object { $_ -notin $accessFailed }

    if ($repositories.Count -eq 0) {
        Write-Host "ERROR: No accessible repositories remaining." -ForegroundColor Red
        exit 1
    }
}

# Step 6: Create Configuration Files
Write-Header "Step 6: Creating Configuration Files"

# Create config.json
$config = @{
    companyId = $companyId
    repositories = $repositories
    backupMaxAgeHours = 24
    backupFilePattern = "*.mrimg"
    skipIfRunning = $true
    runningFilePattern = "backup_running*"
    healthchecksBaseUrl = "https://hc-ping.com"
    autoDetectRepositories = $true
}

$configJson = $config | ConvertTo-Json -Depth 10
$configJson | Out-File -FilePath $ConfigPath -Encoding UTF8 -Force
Write-Host "  Created: $ConfigPath" -ForegroundColor Green

# Create .env
"HC_PING_KEY=$pingKey" | Out-File -FilePath $EnvPath -Encoding UTF8 -Force
Write-Host "  Created: $EnvPath" -ForegroundColor Green

# Step 7: Create Scheduled Task
Write-Header "Step 7: Creating Scheduled Task"

try {
    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "  Removing existing task..." -ForegroundColor Gray
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # Create the scheduled task
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$MonitorScript`"" -WorkingDirectory $ScriptPath

    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable

    $task = Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -User $username `
        -Password $password `
        -Description "Monitors Macrium Reflect backups and reports to healthchecks.io" `
        -RunLevel Highest

    Write-Host "  Scheduled task '$TaskName' created successfully!" -ForegroundColor Green
    Write-Host "  - Runs every hour" -ForegroundColor Gray
    Write-Host "  - Runs as: $username" -ForegroundColor Gray
}
catch {
    Write-Host "  ERROR: Failed to create scheduled task: $_" -ForegroundColor Red
    Write-Host "  You may need to create the task manually in Task Scheduler." -ForegroundColor Yellow
}

# Step 8: Test Run
Write-Header "Step 8: Test Run"
Write-Host "Running a test to verify everything works..." -ForegroundColor Gray
Write-Host ""

try {
    & $MonitorScript
    Write-Host ""
    Write-Host "Test completed!" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "WARNING: Test run encountered errors: $_" -ForegroundColor Yellow
    Write-Host "The scheduled task has been created but may need troubleshooting." -ForegroundColor Yellow
}

# Summary
Write-Header "Installation Complete"

Write-Host "Configuration Summary:" -ForegroundColor Cyan
Write-Host "  Company ID:    $companyId" -ForegroundColor Gray
Write-Host "  Repositories:  $($repositories.Count)" -ForegroundColor Gray
Write-Host "  Task User:     $username" -ForegroundColor Gray
Write-Host "  Task Schedule: Every hour" -ForegroundColor Gray
Write-Host ""

Write-Host "Files Created:" -ForegroundColor Cyan
Write-Host "  $ConfigPath" -ForegroundColor Gray
Write-Host "  $EnvPath" -ForegroundColor Gray
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Check healthchecks.io dashboard for new checks" -ForegroundColor Gray
Write-Host "  2. Configure alerting integrations in healthchecks.io" -ForegroundColor Gray
Write-Host "  3. Verify the scheduled task in Task Scheduler" -ForegroundColor Gray
Write-Host ""

Write-Host "To run manually: .\Monitor-Backups.ps1" -ForegroundColor Yellow
Write-Host ""

#endregion
