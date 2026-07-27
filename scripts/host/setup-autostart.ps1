<#
.SYNOPSIS
3DX Gateway -- one-shot autostart setup for Windows + Docker Desktop.

.DESCRIPTION
Self-contained. Run this ONCE on the gateway server (elevated) to make the
Docker stack come up automatically after a reboot, without an interactive
Docker Desktop sign-in.

Why this is needed: on a Windows host the Docker engine is provided by Docker
Desktop (WSL2 Linux engine). Docker Desktop does NOT start on its own after a
reboot, so the gateway containers never come up and https://<host>/ hangs on
:443 (Caddy not listening). The compose services already carry
`restart: unless-stopped`, so they self-heal once the engine is up -- the only
missing piece is starting the engine at boot.

What it does:
  1. Writes the boot script to <InstallDir>\host\start-3dx-stack.ps1 (copies
     the sibling start-3dx-stack.ps1 if present, else writes an embedded copy).
  2. Registers the "3DX Gateway Autostart" Scheduled Task (trigger: At system
     startup; 1-min delay; run whether logged on or not; highest privileges).

ASCII-only on purpose (PS 5.1 misparses non-ASCII depending on host codepage).

.PARAMETER InstallDir
Compose install dir. Default: C:\ProgramData\3DX-Gateway

.PARAMETER RunAsUser
Account the boot task runs as. Default: current user (DOMAIN\user). Running as
the account that normally launches Docker Desktop is the most reliable choice --
Docker Desktop's WSL2 backend initialises inside that user's profile, which a
SYSTEM-context task may fail to do. You are prompted for the password (stored by
Windows so the task can run non-interactively at boot).

.PARAMETER UseSystem
Register the task to run as SYSTEM instead (no password). Less reliable for
WSL2; use only if a per-user task is not an option.

.PARAMETER BootDelay
ISO-8601 duration to wait after boot before running (default PT1M = 1 minute).

.EXAMPLE
PS> .\setup-autostart.ps1
# Registers the task as the current user (prompts for password), then verify:
PS> Start-ScheduledTask -TaskName '3DX Gateway Autostart'
PS> Get-Content C:\ProgramData\3DX-Gateway\autostart.log -Tail 40
#>

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\ProgramData\3DX-Gateway',
    [string]$TaskName   = '3DX Gateway Autostart',
    [string]$RunAsUser  = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$UseSystem,
    [string]$BootDelay  = 'PT1M'
)

$ErrorActionPreference = 'Stop'

# --- Admin guard -------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this elevated (Run as Administrator)."
}

# --- The boot script (embedded fallback) -------------------------------------
# Logic mirrors scripts/host/start-3dx-stack.ps1 (minus its header block). If
# that file is found next to this one it is copied verbatim; otherwise this
# embedded copy is written (so the script is fully self-contained when pasted
# onto a bare server). Keep the two in sync when editing the boot logic.
$bootScript = @'
param(
    [string]$ComposeDir = 'C:\ProgramData\3DX-Gateway',
    [int]$EngineWaitMinutes = 6
)
$ErrorActionPreference = 'Continue'
$LogFile = Join-Path $ComposeDir 'autostart.log'
function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}
Log "=== 3DX Gateway autostart begin (ComposeDir=$ComposeDir) ==="
try {
    $svc = Get-Service -Name 'com.docker.service' -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Log "com.docker.service is $($svc.Status) -> starting"
        Start-Service -Name 'com.docker.service'
    } else {
        Log "com.docker.service already running"
    }
} catch {
    Log "WARN: com.docker.service not found/startable: $($_.Exception.Message)"
}
$dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if (Test-Path $dd) {
    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Log "Launching Docker Desktop"
        Start-Process -FilePath $dd
    } else {
        Log "Docker Desktop process already present"
    }
} else {
    Log "WARN: Docker Desktop.exe not found at $dd (engine may still come up via service)"
}
$deadline = (Get-Date).AddMinutes($EngineWaitMinutes)
$ready = $false
while (-not $ready -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $ver = docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $ver) {
        $ready = $true
        Log "Docker engine ready (Server $ver)"
    } else {
        Log "Waiting for Docker engine..."
    }
}
if (-not $ready) {
    Log "ERROR: Docker engine did not become ready within $EngineWaitMinutes min. Aborting."
    exit 1
}
if (-not (Test-Path $ComposeDir)) {
    Log "ERROR: ComposeDir $ComposeDir not found. Aborting."
    exit 1
}
Set-Location -Path $ComposeDir
Log "Running: docker compose up -d"
$out = docker compose up -d 2>&1
foreach ($l in $out) { Log "  $l" }
Log "compose up -d exit code: $LASTEXITCODE"
$ps = docker compose ps 2>&1
foreach ($l in $ps) { Log "  $l" }
Log "=== 3DX Gateway autostart end ==="
exit 0
'@

# --- 1. Write the boot script ------------------------------------------------
$hostDir = Join-Path $InstallDir 'host'
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
$startScript = Join-Path $hostDir 'start-3dx-stack.ps1'

$sibling = Join-Path $PSScriptRoot 'start-3dx-stack.ps1'
if ((Test-Path $sibling) -and ((Resolve-Path $sibling).Path -ne (Join-Path $hostDir 'start-3dx-stack.ps1'))) {
    Copy-Item -Path $sibling -Destination $startScript -Force
    Write-Host "Copied boot script from $sibling"
} else {
    Set-Content -Path $startScript -Value $bootScript -Encoding ASCII
    Write-Host "Wrote embedded boot script to $startScript"
}

# --- 2. Register the Scheduled Task ------------------------------------------
$psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command powershell).Source }

$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startScript`""

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = $BootDelay   # ISO-8601 duration, e.g. PT1M = 1 minute

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 2)

# Idempotent: drop an existing task with the same name first.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if ($UseSystem) {
    Write-Host "Registering '$TaskName' to run as SYSTEM..."
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
} else {
    Write-Host "Registering '$TaskName' to run as $RunAsUser (run whether logged on or not)..."
    $cred = Get-Credential -UserName $RunAsUser `
        -Message "Password for $RunAsUser (stored by Windows so the task runs at boot)"
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $trigger -Settings $settings `
        -User $cred.UserName `
        -Password $cred.GetNetworkCredential().Password `
        -RunLevel Highest | Out-Null
}

Write-Host ""
Write-Host "Done. The stack will start automatically on the next boot." -ForegroundColor Green
Write-Host ""
Write-Host "Test it now without rebooting:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Start-Sleep 20"
Write-Host "  Get-Content '$(Join-Path $InstallDir 'autostart.log')' -Tail 40"
Write-Host "  (Test-NetConnection -ComputerName localhost -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded"
Write-Host ""
Write-Host "Remove later with:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
