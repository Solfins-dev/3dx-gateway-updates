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
#   4. Runs `docker compose <the install's real -f set> up -d` in the compose dir.
#
# Step 4 MUST pass the install's overlay set. A bare `docker compose up -d`
# reconciles against docker-compose.yml ONLY, which silently RECREATES the app
# container without the overlays: the Apply Update helper wiring
# (Updates__HelperEndpoint / Updates__HelperToken / Updates__HostKind) and the
# Caddy TLS service vanish. Symptoms seen on delmiaworks04 after the 2026-06-30
# autostart landed: Settings -> Updates shows "one-click update not available"
# plus a Linux ssh fallback command on a Windows host, and `3dx-gateway-caddy`
# is reported as an orphan container.
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

# Resolve the install's real compose file set, same precedence the Apply Update
# worker uses: (1) the authoritative manifest written by install.ps1 -AddHelper /
# install-helper.ps1, (2) an on-disk probe of the known overlay names. Never a
# bare `up -d` when overlays exist -- that is the drift that strips helper + TLS.
function Resolve-ComposeArgs([string]$dir) {
    $setFile = Join-Path $env:ProgramData '3dx-gateway\compose-set.json'
    if (Test-Path $setFile) {
        try {
            $s = Get-Content -Path $setFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $files = @($s.composeFiles | Where-Object { $_ })
            $missing = @($files | Where-Object { -not (Test-Path $_) })
            if ($files.Count -gt 0 -and $missing.Count -eq 0) {
                $a = @()
                if ($s.project) { $a += @('--project-name', $s.project) }
                foreach ($f in $files) { $a += @('-f', $f) }
                if ($s.envFile -and (Test-Path $s.envFile)) { $a += @('--env-file', $s.envFile) }
                return @{ Args = $a; Source = 'compose-set.json' }
            }
            if ($missing.Count -gt 0) {
                Log "WARN: compose-set.json lists missing file(s): $($missing -join '; ') -- falling back to on-disk probe"
            } else {
                Log "WARN: compose-set.json has no composeFiles -- falling back to on-disk probe"
            }
        } catch {
            Log "WARN: compose-set.json unreadable ($($_.Exception.Message)) -- falling back to on-disk probe"
        }
    }

    # Probe. The helper overlay interpolates `${HELPER_TOKEN:?...}`, so including
    # it without a token in .env would fail the WHOLE `up -d` and leave the
    # gateway down at boot -- worse than losing one-click. Include it only when
    # the token is actually there.
    $hasToken = $false
    $envPath = Join-Path $dir '.env'
    if (Test-Path $envPath) {
        try { $hasToken = [bool](Select-String -Path $envPath -Pattern '^\s*HELPER_TOKEN\s*=\s*\S' -Quiet) } catch { }
    }
    $a = @()
    foreach ($n in @('docker-compose.yml', 'docker-compose.tls.yml', 'docker-compose.helper.windows.yml')) {
        $p = Join-Path $dir $n
        if (-not (Test-Path $p)) { continue }
        if ($n -eq 'docker-compose.helper.windows.yml' -and -not $hasToken) {
            Log "WARN: $n present but HELPER_TOKEN missing from .env -- skipping it (one-click Apply stays unavailable; re-run install.ps1 -AddHelper to fix)"
            continue
        }
        $a += @('-f', $n)
    }
    return @{ Args = $a; Source = 'on-disk probe' }
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
$ctx = Resolve-ComposeArgs $ComposeDir
$composeArgs = @($ctx.Args)
Log "compose set ($($ctx.Source)): docker compose $($composeArgs -join ' ') up -d"
$out = docker compose @composeArgs up -d 2>&1
foreach ($l in $out) { Log "  $l" }
$upExit = $LASTEXITCODE
Log "compose up -d exit code: $upExit"

# Boot resilience: if the full set fails (bad overlay, missing var), still get
# the gateway up with the base file rather than leaving the server dark. Loud
# WARN because the app then runs WITHOUT the overlays -- one-click Apply and
# Caddy TLS are degraded until the operator fixes the set.
if ($upExit -ne 0 -and $composeArgs.Count -gt 2) {
    Log "WARN: up -d failed with the full overlay set -- retrying with docker-compose.yml only so the gateway is at least reachable."
    Log "WARN: after this fallback the app runs WITHOUT the TLS/helper overlays. Fix with: install.ps1 -AddHelper -NoRecreate"
    $out = docker compose -f docker-compose.yml up -d 2>&1
    foreach ($l in $out) { Log "  $l" }
    Log "fallback compose up -d exit code: $LASTEXITCODE"
    $composeArgs = @('-f', 'docker-compose.yml')
}

# 5. Quick confirmation -------------------------------------------------------
$ps = docker compose @composeArgs ps 2>&1
foreach ($l in $ps) { Log "  $l" }

Log "=== 3DX Gateway autostart end ==="
exit 0
