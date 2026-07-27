# start-3dx-stack.ps1
# ---------------------------------------------------------------------------
# Boot-time autostart for the 3DX Gateway Docker stack.
#
# Problem this solves: on delmiaworks04 the Docker engine is provided by Docker
# Desktop (WSL2 Linux engine). After a server reboot Docker Desktop does NOT
# start on its own (it needs an interactive sign-in), so the gateway containers
# never come up and https://<host>/ hangs on :443 (Caddy not listening).
#
# This script is launched by the "3DX Gateway Autostart" Scheduled Task
# (trigger: At system startup; see register-autostart-task.ps1). It:
#   1. Ensures the privileged engine service (com.docker.service) is running.
#   2. Launches Docker Desktop so the WSL2 Linux engine initialises.
#   3. Waits until `docker version` returns a Server (engine ready).
#   4. Runs `docker compose up -d` in the compose directory.
#
# The compose services already carry `restart: unless-stopped`, so once the
# engine is up Docker restores them automatically; the explicit `compose up -d`
# is a belt-and-braces step that also covers a fresh/clean engine state and the
# externally-managed caddy container.
#
# All output is appended to <ComposeDir>\autostart.log for post-mortem.
# ---------------------------------------------------------------------------

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

# 1. Privileged engine service ------------------------------------------------
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

# 2. Launch Docker Desktop (inits the WSL2 Linux engine) ----------------------
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

# 3. Wait for the Linux engine to answer --------------------------------------
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

# 4. Bring up the stack -------------------------------------------------------
if (-not (Test-Path $ComposeDir)) {
    Log "ERROR: ComposeDir $ComposeDir not found. Aborting."
    exit 1
}
Set-Location -Path $ComposeDir
Log "Running: docker compose up -d"
$out = docker compose up -d 2>&1
foreach ($l in $out) { Log "  $l" }
Log "compose up -d exit code: $LASTEXITCODE"

# 5. Quick confirmation -------------------------------------------------------
$ps = docker compose ps 2>&1
foreach ($l in $ps) { Log "  $l" }

Log "=== 3DX Gateway autostart end ==="
exit 0
