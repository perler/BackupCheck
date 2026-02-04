<#
.SYNOPSIS
    Installs and configures the BackupCheck monitoring solution.

.DESCRIPTION
    This script guides you through setting up the backup monitoring solution:
    - Prompts for Company ID and healthchecks.io ping key
    - Auto-detects Macrium Reflect backup repositories
    - Configures repository credentials (stored in Windows Credential Manager)
    - Configures scheduled task credentials (Windows/AD account)
    - Creates configuration files
    - Sets up a Windows Scheduled Task to run hourly

.NOTES
    Version: 0.3.0
    Requires: PowerShell 5.1+, Administrator privileges
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Force TLS 1.2 for all HTTPS connections (required by healthchecks.io)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
            $inputValue = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
            )
        }
        else {
            $inputValue = Read-Host "$displayPrompt"
        }

        if ([string]::IsNullOrWhiteSpace($inputValue) -and $Default) {
            $inputValue = $Default
        }

        if ($Required -and [string]::IsNullOrWhiteSpace($inputValue)) {
            Write-Host "This field is required." -ForegroundColor Red
        }
    } while ($Required -and [string]::IsNullOrWhiteSpace($inputValue))

    return $inputValue
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

function Get-ServerNameFromUNC {
    <#
    .SYNOPSIS
        Extracts the server/NAS name from a UNC path.
    .EXAMPLE
        Get-ServerNameFromUNC "\\nas002\backup_srv" returns "nas002"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UNCPath
    )

    if ($UNCPath -match "^\\\\([^\\]+)\\") {
        return $matches[1]
    }
    return $null
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
        # Force TLS 1.2 (required by healthchecks.io, older Windows may default to TLS 1.0)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Test that we can reach the service
        $response = Invoke-WebRequest -Uri "https://hc-ping.com/$PingKey/test-connection?create=1" -Method POST -UseBasicParsing -TimeoutSec 10
        return @{ Success = $true; Error = $null }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Save-CredentialToManager {
    <#
    .SYNOPSIS
        Saves credentials to Windows Credential Manager.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$Password
    )

    # Use cmdkey to store credentials
    $result = cmdkey /add:$Target /user:$Username /pass:$Password 2>&1
    return $LASTEXITCODE -eq 0
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
Write-Host "  Backup Monitoring Installer v0.3.0" -ForegroundColor Gray
Write-Host ""

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "WARNING: Running without Administrator privileges." -ForegroundColor Yellow
    Write-Host "         Scheduled task creation may fail." -ForegroundColor Yellow
    Write-Host ""
}

# Check for existing .env file
$existingEnv = $null
if (Test-Path $EnvPath) {
    Write-Host "Found existing .env file" -ForegroundColor Green
    $existingEnv = Get-EnvFile -Path $EnvPath
}

# Check for existing config.json
$existingConfig = $null
if (Test-Path $ConfigPath) {
    Write-Host "Found existing config.json" -ForegroundColor Green
    $existingConfig = Get-Content $ConfigPath | ConvertFrom-Json
}

# Step 1: Company ID
Write-Header "Step 1: Company Configuration"
Write-Host "The Company ID is used as a prefix for all health check names." -ForegroundColor Gray
Write-Host "Example: If Company ID is 'LTHX', checks will be named 'lthx-wks001', 'lthx-srv003', etc." -ForegroundColor Gray
Write-Host ""

$defaultCompanyId = if ($existingConfig.companyId) { $existingConfig.companyId } else { "" }
$companyId = Get-UserInput -Prompt "Enter Company ID (e.g., LTHX)" -Default $defaultCompanyId -Required
$companyId = $companyId.ToUpper()

# Step 2: healthchecks.io Configuration
Write-Header "Step 2: healthchecks.io Configuration"

$pingKey = $null
$apiKey = $null

if ($existingEnv -and $existingEnv["HC_PING_KEY"] -and $existingEnv["HC_API_KEY"]) {
    Write-Host "Using existing healthchecks.io keys from .env" -ForegroundColor Green
    $pingKey = $existingEnv["HC_PING_KEY"]
    $apiKey = $existingEnv["HC_API_KEY"]
}
else {
    Write-Host "You need keys from your healthchecks.io project." -ForegroundColor Gray
    Write-Host "Find them at: Project Settings > API Access" -ForegroundColor Gray
    Write-Host ""

    $pingKey = Get-UserInput -Prompt "Enter Ping Key" -Required
    $apiKey = Get-UserInput -Prompt "Enter API Key (for management)" -Required
}

# Always test connection
Write-Host ""
Write-Host "Testing healthchecks.io connection..." -ForegroundColor Gray
$connectionTest = Test-HealthChecksConnection -PingKey $pingKey
if ($connectionTest.Success) {
    Write-Host "  Connection successful!" -ForegroundColor Green

    # Clean up the test-connection check
    Write-Host "  Cleaning up test check..." -ForegroundColor Gray
    try {
        $headers = @{ "X-Api-Key" = $apiKey }
        $checks = Invoke-RestMethod -Uri "https://healthchecks.io/api/v3/checks/" -Headers $headers -Method Get
        $testCheck = $checks.checks | Where-Object { $_.slug -eq "test-connection" }
        if ($testCheck) {
            $deleteUrl = "https://healthchecks.io/api/v3/checks/$($testCheck.ping_url.Split('/')[-1])"
            Invoke-RestMethod -Uri $deleteUrl -Headers $headers -Method Delete | Out-Null
            Write-Host "  Test check removed." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  Could not remove test check: $_" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  WARNING: Could not verify connection to healthchecks.io" -ForegroundColor Yellow
    if ($connectionTest.Error) {
        Write-Host "  Error: $($connectionTest.Error)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Possible causes:" -ForegroundColor Yellow
    Write-Host "    - Invalid ping key" -ForegroundColor Gray
    Write-Host "    - Firewall blocking hc-ping.com" -ForegroundColor Gray
    Write-Host "    - TLS/SSL issues (requires TLS 1.2)" -ForegroundColor Gray
    Write-Host ""
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

# Step 4: Repository Credentials
Write-Header "Step 4: Repository Credentials"
Write-Host "These credentials are used to access the backup repositories (NAS/file shares)." -ForegroundColor Gray
Write-Host "The credentials will be stored in Windows Credential Manager." -ForegroundColor Gray
Write-Host ""

# Extract server name from first UNC path for domain default
$serverName = $null
foreach ($repo in $repositories) {
    $serverName = Get-ServerNameFromUNC -UNCPath $repo
    if ($serverName) { break }
}

if ($serverName) {
    Write-Host "Detected server name from repository path: $serverName" -ForegroundColor Green
    Write-Host "This will be used as the domain for repository credentials." -ForegroundColor Gray
    Write-Host ""
}

$repoUsername = Get-UserInput -Prompt "Repository username (without domain)" -Required
$repoPassword = Get-UserInput -Prompt "Repository password" -Required -IsSecure

# Build full username with domain from server name
if ($serverName) {
    $repoFullUsername = "$serverName\$repoUsername"
}
else {
    $repoFullUsername = $repoUsername
}

# Create credential object for testing
$repoSecurePassword = ConvertTo-SecureString $repoPassword -AsPlainText -Force
$repoCredential = New-Object System.Management.Automation.PSCredential($repoFullUsername, $repoSecurePassword)

# Step 5: Validate Repository Access
Write-Header "Step 5: Validating Repository Access"

$accessFailed = @()
foreach ($repo in $repositories) {
    Write-Host "  Testing: $repo ... " -NoNewline -ForegroundColor Gray

    if (Test-RepositoryAccess -Path $repo -Credential $repoCredential) {
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

# Store repository credentials in Credential Manager
Write-Host ""
Write-Host "Storing repository credentials in Windows Credential Manager..." -ForegroundColor Gray

# Get unique server names from all repositories
$serverNames = @()
foreach ($repo in $repositories) {
    $srvName = Get-ServerNameFromUNC -UNCPath $repo
    if ($srvName -and $srvName -notin $serverNames) {
        $serverNames += $srvName
    }
}

foreach ($srv in $serverNames) {
    if (Save-CredentialToManager -Target $srv -Username $repoFullUsername -Password $repoPassword) {
        Write-Host "  Stored credentials for: $srv" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to store credentials for: $srv" -ForegroundColor Yellow
    }
}

# Step 6: Scheduled Task Credentials
Write-Header "Step 6: Scheduled Task Credentials"
Write-Host "These credentials are used to run the scheduled task on this server." -ForegroundColor Gray
Write-Host "This should be a Windows/Active Directory account." -ForegroundColor Gray
Write-Host ""
Write-Host "See IT-Portal for the 'automat' service account credentials." -ForegroundColor Yellow
Write-Host ""

$taskUsername = Get-UserInput -Prompt "Task username (DOMAIN\user)" -Default "AD\automat" -Required
$taskPassword = Get-UserInput -Prompt "Task password (see IT-Portal)" -Required -IsSecure

# Step 7: Create Configuration Files
Write-Header "Step 7: Creating Configuration Files"

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
@"
HC_PING_KEY=$pingKey
HC_API_KEY=$apiKey
"@ | Out-File -FilePath $EnvPath -Encoding UTF8 -Force
Write-Host "  Created: $EnvPath" -ForegroundColor Green

# Step 8: Create Scheduled Task
Write-Header "Step 8: Creating Scheduled Task"

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
        -User $taskUsername `
        -Password $taskPassword `
        -Description "Monitors Macrium Reflect backups and reports to healthchecks.io" `
        -RunLevel Highest

    Write-Host "  Scheduled task '$TaskName' created successfully!" -ForegroundColor Green
    Write-Host "  - Runs every hour" -ForegroundColor Gray
    Write-Host "  - Runs as: $taskUsername" -ForegroundColor Gray
}
catch {
    Write-Host "  ERROR: Failed to create scheduled task: $_" -ForegroundColor Red
    Write-Host "  You may need to create the task manually in Task Scheduler." -ForegroundColor Yellow
}

# Step 9: Test Run
Write-Header "Step 9: Test Run"
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
Write-Host "  Company ID:        $companyId" -ForegroundColor Gray
Write-Host "  Repositories:      $($repositories.Count)" -ForegroundColor Gray
Write-Host "  Repo Credentials:  $repoFullUsername (stored in Credential Manager)" -ForegroundColor Gray
Write-Host "  Task User:         $taskUsername" -ForegroundColor Gray
Write-Host "  Task Schedule:     Every hour" -ForegroundColor Gray
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
