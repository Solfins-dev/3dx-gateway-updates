<#
.SYNOPSIS
3DX Gateway -- Windows uninstaller / clean-slate teardown.

.DESCRIPTION
Reverses what install.ps1 did, so the box is ready for a fresh install:
  - docker compose down (removes the app/db/caddy containers; -v wipes the
    named volumes too unless -KeepData).
  - Belt-and-braces removal of the 3dx-gateway-* containers + project volumes
    by name in case compose state is gone.
  - Unregisters the "3dx-gateway-helper" Scheduled Task (Apply Update helper).
  - Removes the install dir (C:\ProgramData\3DX-Gateway) AND the helper state
    dir (C:\ProgramData\3dx-gateway) -- the two dirs whose leftover presence
    made install.ps1's idempotency guard reject a re-run.
  - Optionally removes the pulled Docker images (-RemoveImages).

It NEVER touches IIS, other services, or anything outside its own install +
state dirs and its own containers/volumes. Safe to run on a half-finished
install (each step is independent + non-fatal).

ASCII-only by hard rule (PS 5.1 misparses non-ASCII depending on codepage).

.PARAMETER InstallDir
Install location to tear down. Default: C:\ProgramData\3DX-Gateway

.PARAMETER KeepData
Keep the Docker named volumes (pgdata / app_data / caddy_*) so a reinstall
keeps the database + settings. Default: volumes ARE wiped (full clean).

.PARAMETER RemoveImages
Also `docker rmi` the gateway / postgres / caddy images. Default: images kept
(a reinstall then doesn't re-pull ~hundreds of MB).

.PARAMETER Yes
Unattended: skip the confirmation prompt.

.EXAMPLE
PS> .\uninstall.ps1                 # full clean (containers + volumes + dirs)

.EXAMPLE
PS> .\uninstall.ps1 -KeepData -Yes  # remove containers + dirs, keep the DB

.LINK
https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/INSTALL.md
#>

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\ProgramData\3DX-Gateway',
    [switch]$KeepData,
    [switch]$RemoveImages,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# Native non-zero exits must NOT be terminating here (PS7 default flips them):
# `docker` / `schtasks` returning non-zero on already-gone resources is normal
# during a teardown and must not abort the rest of the cleanup. See install.ps1.
$PSNativeCommandUseErrorActionPreference = $false

$UNINSTALLER_VERSION = '1.7.0'
$STATE_DIR  = 'C:\ProgramData\3dx-gateway'           # helper token/status dir
$TASK_NAME  = '3dx-gateway-helper'
$CONTAINERS = @('3dx-gateway-app', '3dx-gateway-db', '3dx-gateway-caddy')
$IMAGES     = @('ghcr.io/solfins-dev/3dx-gateway:latest', 'postgres:16-alpine', 'caddy:2.9-alpine')

#--- Output helpers ---------------------------------------------------------

function Write-Step    { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Substep { param([string]$Text) Write-Host "    $Text" }
function Write-Ok      { param([string]$Text) Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Hr      { Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ComposeDownFlags {
    # Build `-f X -f Y ...` from whatever compose files this install actually
    # wrote. Only include files that exist so `docker compose` doesn't error on
    # a missing overlay (e.g. a -Tls none install has no tls overlay).
    $flags = @()
    foreach ($f in @('docker-compose.yml', 'docker-compose.tls.yml', 'docker-compose.helper.windows.yml')) {
        if (Test-Path (Join-Path $InstallDir $f)) { $flags += @('-f', $f) }
    }
    return $flags
}

#--- Teardown steps ---------------------------------------------------------

function Invoke-ComposeDown {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warn2 "docker not on PATH; skipping compose down (will remove containers by name)."
        return
    }
    if (-not (Test-Path (Join-Path $InstallDir 'docker-compose.yml'))) {
        Write-Substep "No docker-compose.yml in $InstallDir; skipping compose down."
        return
    }
    Write-Step "Stopping the stack (docker compose down)"
    $flags = Get-ComposeDownFlags
    $down = @('compose') + $flags + @('down', '--remove-orphans')
    if (-not $KeepData) { $down += '-v' }
    Push-Location $InstallDir
    # docker compose writes its progress ("Container X Stopping/Removing") to
    # STDERR. With 2>&1 those lines merge into the pipeline as ErrorRecords, and
    # under $ErrorActionPreference='Stop' PowerShell renders each one as a scary
    # "NativeCommandError" block even though nothing failed. Drop EAP to
    # Continue around the call so the progress prints as plain text.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @down 2>&1 | ForEach-Object { Write-Substep ([string]$_) }
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            $vmsg = if ($KeepData) { '(volumes kept)' } else { '(volumes removed)' }
            Write-Ok "Stack down $vmsg"
        } else {
            Write-Warn2 "compose down returned $code; falling back to remove-by-name."
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        Pop-Location
    }
}

function Remove-ContainersByName {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
    Write-Step "Removing leftover containers by name"
    foreach ($c in $CONTAINERS) {
        $id = (& docker ps -aq --filter "name=^$c$" 2>$null)
        if ($id) {
            & docker rm -f $c 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "removed $c" } else { Write-Warn2 "could not remove $c" }
        }
    }
}

function Remove-VolumesByName {
    if ($KeepData) { Write-Substep "Keeping Docker volumes (-KeepData)."; return }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
    Write-Step "Removing leftover named volumes"
    # compose down -v already removed the project volumes; this catches any left
    # behind (e.g. compose state lost). Project name = install dir leaf, lowercased.
    $proj = (Split-Path -Leaf $InstallDir).ToLower() -replace '[^a-z0-9]', ''
    $patterns = @("$proj`_", '3dxgateway_', '3dx-gateway_')
    $vols = (& docker volume ls -q 2>$null)
    foreach ($v in $vols) {
        foreach ($pat in $patterns) {
            if ($v -like "$pat*") {
                & docker volume rm $v 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Ok "removed volume $v" }
                break
            }
        }
    }
}

function Remove-GatewayImages {
    if (-not $RemoveImages) { return }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
    Write-Step "Removing Docker images (-RemoveImages)"
    foreach ($img in $IMAGES) {
        $iid = (& docker images -q $img 2>$null)
        if ($iid) {
            & docker rmi $img 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "removed image $img" } else { Write-Warn2 "could not remove image $img (in use?)" }
        }
    }
}

function Remove-HelperTask {
    Write-Step "Removing Apply Update helper Scheduled Task"
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if (-not $task) { Write-Substep "Task '$TASK_NAME' not registered; nothing to do."; return }
    try {
        Stop-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction Stop
        Write-Ok "Scheduled Task '$TASK_NAME' removed"
    } catch {
        Write-Warn2 "Could not remove task '$TASK_NAME': $($_.Exception.Message)"
    }
}

function Remove-Dir {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { Write-Substep "$Label not present ($Path)."; return }
    try {
        # .env is ACL-locked to Admins+SYSTEM; an elevated admin (us) has
        # FullControl, so -Force removes it cleanly.
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Ok "$Label removed ($Path)"
    } catch {
        Write-Warn2 "Could not fully remove $Label ($Path): $($_.Exception.Message)"
        Write-Substep "If files are locked, ensure Docker Desktop is idle and re-run."
    }
}

#--- Main -------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host "3DX Gateway Uninstaller v$UNINSTALLER_VERSION (Windows)" -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdmin)) {
        Write-Warn2 "Run this from an elevated PowerShell (Run as Administrator)."
        throw "Administrator privileges required."
    }

    Write-Hr
    Write-Host '  This will remove:' -ForegroundColor Yellow
    Write-Host "    - containers:   $($CONTAINERS -join ', ')"
    Write-Host "    - volumes:      $(if ($KeepData) { 'KEPT (-KeepData)' } else { 'REMOVED (database + settings wiped)' })"
    Write-Host "    - images:       $(if ($RemoveImages) { 'REMOVED (-RemoveImages)' } else { 'kept' })"
    Write-Host "    - helper task:  $TASK_NAME"
    Write-Host "    - install dir:  $InstallDir"
    Write-Host "    - state dir:    $STATE_DIR"
    Write-Host '  It does NOT touch IIS or any other service.'
    Write-Hr
    if (-not $Yes.IsPresent) {
        $ans = Read-Host "  Proceed? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Host '  Cancelled.'; return }
    }

    Invoke-ComposeDown
    Remove-ContainersByName
    Remove-VolumesByName
    Remove-GatewayImages
    Remove-HelperTask
    Remove-Dir -Path $InstallDir -Label 'Install dir'
    Remove-Dir -Path $STATE_DIR  -Label 'Helper state dir'

    Write-Hr
    Write-Host ''
    Write-Host '[OK] 3DX Gateway uninstalled.' -ForegroundColor Green
    if (-not $KeepData) {
        Write-Host '     Database + settings were wiped. A fresh install starts clean.'
    } else {
        Write-Host '     Docker volumes were kept; a reinstall to the same dir reuses them.'
    }
    Write-Host ''
}

Main
