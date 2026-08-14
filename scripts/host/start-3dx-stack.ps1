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
# (triggers: At system startup, At log on, plus a retry repetition; see
# setup-autostart.ps1). It:
#   0. Audits its own scheduled-task registration against the contract manifest
#      that setup-autostart.ps1 stamped, and reports whether Docker Desktop is
#      still allowed to update itself. Both are logged on every run.
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
    [int]$EngineWaitMinutes = 6,
    [string]$TaskName = '3DX Gateway Autostart'
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

# --- Self-audit: is the task that just ran the task we ship? ------------------
# On 2026-08-10 the post-mortem found the delivered fix and the registered task
# had been out of step for five weeks: setup-autostart.ps1 in the repo had grown
# an At-Log-On trigger and a retry repetition on 2026-08-07, but the task on the
# server still carried a lone boot trigger with LastTaskResult=1 and an empty
# NextRunTime. Shipping a script is not the same act as registering a task, and
# nothing anywhere compared the two. So the boot script now compares them itself,
# on every single run, and says so in the log that a human already reads.
#
# This is deliberately a LIGHT check against the contract manifest that
# setup-autostart.ps1 stamps at registration time. The authoritative, detailed
# comparison lives in setup-autostart.ps1 -CheckOnly; this one only has to be
# loud enough that nobody can stare at autostart.log for 36 hours and miss it.
function Test-AutostartRegistration([string]$dir, [string]$taskName) {
    $manifest = Join-Path $dir 'host\autostart-contract.json'
    if (-not (Test-Path $manifest)) {
        Log "NOTE: no autostart contract at $manifest -- this task was registered by a setup script older than"
        Log "      2026-08-10, so its shape cannot be verified. Re-run scripts/host/setup-autostart.ps1 (elevated)."
        return
    }
    $c = $null
    try { $c = Get-Content -Path $manifest -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Log "WARN: autostart contract unreadable ($($_.Exception.Message)) -- skipping the registration self-audit"; return }

    $task = $null
    try { $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop }
    catch {
        Log "DRIFT: scheduled task '$taskName' is NOT registered, but the contract file says it should be (v$($c.contractVersion))."
        return
    }

    $d = @()
    $kinds = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
    foreach ($want in @($c.triggerClasses)) {
        if ($want -and ($kinds -notcontains $want)) { $d += "missing trigger $want (registered: $($kinds -join ', '))" }
    }
    if ($c.repetitionInterval) {
        $rep = $null
        foreach ($t in $task.Triggers) {
            if ($t.Repetition -and $t.Repetition.Interval) { $rep = $t.Repetition.Interval; break }
        }
        if (-not $rep) { $d += "no repeating trigger at all (contract wants every $($c.repetitionInterval)) -- a failed boot attempt is never retried" }
        elseif ($rep -ne $c.repetitionInterval) { $d += "repetition is $rep, contract wants $($c.repetitionInterval)" }
    }
    if ($task.Actions -and $task.Actions.Count -gt 0) {
        if ($c.actionArguments -and $task.Actions[0].Arguments -ne $c.actionArguments) {
            $d += "action arguments differ (registered: $($task.Actions[0].Arguments))"
        }
    } else {
        $d += "task has no action"
    }
    $regVer = ''
    if ($task.Description -match '3dx-autostart-contract\s+v=([^\s\]]+)') { $regVer = $Matches[1] }
    if ($regVer -ne [string]$c.contractVersion) {
        $d += "registered contract v='$regVer', delivered contract v='$($c.contractVersion)'"
    }

    if ($d.Count -eq 0) {
        Log "autostart registration matches the delivered contract (v$($c.contractVersion))"
        return
    }
    foreach ($x in $d) { Log "DRIFT: $x" }
    Log "DRIFT: the registered task no longer matches the autostart contract that shipped with this install."
    Log "       Fix (elevated):  powershell -ExecutionPolicy Bypass -File <install>\host\setup-autostart.ps1"
    Log "       Inspect only:    powershell -ExecutionPolicy Bypass -File <install>\host\setup-autostart.ps1 -CheckOnly"
}

# --- Is Docker Desktop still allowed to update itself under us? --------------
# Root cause of the 2026-08-08 20:02 outage: Docker Desktop updated ITSELF
# (Windows System log 7034 "Docker Desktop Service terminated unexpectedly"
# followed by 7045 re-installing the service, engine 29.5.3 -> 29.6.2). The
# updater killed the engine, so `restart: unless-stopped` had nothing left to
# restart -- the container did not fail, the engine underneath it vanished --
# and with nobody signed in it never came back. One log line per run, so the
# next post-mortem does not have to reconstruct this from event logs again.
function Show-DockerUpdateGuard {
    $p = Join-Path $env:ProgramData 'DockerDesktop\admin-settings.json'
    if (-not (Test-Path $p)) {
        Log "NOTE: Docker Desktop auto-update is not pinned on this host (no $p)."
        Log "      A self-update took the engine down on 2026-08-08 and the stack stayed down for 36 h."
        Log "      Pin it with (elevated):  setup-autostart.ps1 -DisableDockerAutoUpdate"
        return
    }
    try {
        $j = Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.disableUpdate -and $j.disableUpdate.value -eq $true) {
            Log "Docker Desktop auto-update pinned off via admin-settings.json (locked=$($j.disableUpdate.locked))"
        } else {
            Log "NOTE: $p exists but disableUpdate is not value=true -- Docker Desktop may still update itself."
        }
    } catch {
        Log "WARN: $p is unreadable ($($_.Exception.Message)) -- cannot tell whether auto-update is pinned."
    }
}

Log "=== 3DX Gateway autostart begin (ComposeDir=$ComposeDir) ==="

# --- Engine helpers ----------------------------------------------------------
function Get-EngineVersion {
    $v = docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { return $v }
    return $null
}

# Tear down a half-started Docker Desktop. A boot-time task runs in SESSION 0,
# where Docker Desktop's WSL2 backend cannot initialise -- but the process still
# starts and LINGERS. Every later attempt then sees a Docker Desktop process,
# concludes "already running", and waits for an engine that will never arrive.
# That wreck is why the operator's own manual run could not recover the server on
# 2026-08-07 either. Never leave one behind.
function Reset-DockerDesktop {
    $names = @('Docker Desktop','com.docker.backend','com.docker.build','com.docker.dev-envs','vpnkit','vpnkit-bridge')
    $killed = 0
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $killed++ } catch { }
        }
    }
    if ($killed -gt 0) { Log "reaped $killed stale Docker Desktop process(es)" }
    try { & wsl.exe --shutdown 2>&1 | Out-Null } catch { }
    try {
        $s = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
        if ($s) { Restart-Service -Name 'com.docker.service' -Force -ErrorAction SilentlyContinue }
    } catch { }
    Start-Sleep -Seconds 5
}

# Session 0 = no interactive desktop (boot-time task). Docker Desktop is a GUI
# application; its engine CANNOT come up there. Knowing this up front turns a
# six-minute mystery into one honest log line.
$sessionId = try { (Get-Process -Id $PID).SessionId } catch { -1 }
$interactive = $sessionId -gt 0

# A real Docker ENGINE service (Docker CE / Mirantis) is a true Windows service
# with no session requirement. When it exists, unattended boot works and Docker
# Desktop is irrelevant to us.
$engineSvc = Get-Service -Name 'docker' -ErrorAction SilentlyContinue

Log "session=$sessionId (interactive=$interactive), engine service '$(if ($engineSvc) { 'docker' } else { 'none' })'"

# Both audits run BEFORE the engine wait, so they are on the record even when
# the run later dies waiting for a Docker engine that never arrives.
try { Test-AutostartRegistration -dir $ComposeDir -taskName $TaskName } catch { Log "WARN: registration self-audit failed: $($_.Exception.Message)" }
try { Show-DockerUpdateGuard } catch { Log "WARN: update-guard check failed: $($_.Exception.Message)" }

# 1. Engine services ----------------------------------------------------------
if ($engineSvc) {
    if ($engineSvc.Status -ne 'Running') {
        Log "docker engine service is $($engineSvc.Status) -> starting"
        try { Start-Service -Name 'docker' } catch { Log "WARN: could not start 'docker' service: $($_.Exception.Message)" }
    } else {
        Log "docker engine service already running"
    }
}
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

# 2. Wait for the engine, reaping a wedged Docker Desktop once ----------------
# Health, never process presence, is the readiness test: a Docker Desktop process
# that exists proves nothing about whether `docker` can talk to a daemon.
$dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$deadline = (Get-Date).AddMinutes($EngineWaitMinutes)
$graceEnd = (Get-Date).AddSeconds(60)     # how long a present-but-silent Desktop gets before it is reaped
$reaped = $false
$ready = $false
$launched = $false

while (-not $ready -and (Get-Date) -lt $deadline) {
    $ver = Get-EngineVersion
    if ($ver) { $ready = $true; Log "Docker engine ready (Server $ver)"; break }

    $ddProc = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    if (-not $ddProc) {
        if (Test-Path $dd) {
            if (-not $interactive) {
                Log "NOTE: launching Docker Desktop from session 0 -- its WSL2 backend cannot initialise without an interactive sign-in. Trying anyway; the wreck is cleaned up if it fails."
            }
            Log "Launching Docker Desktop"
            try { Start-Process -FilePath $dd } catch { Log "WARN: could not launch Docker Desktop: $($_.Exception.Message)" }
            $launched = $true
            $graceEnd = (Get-Date).AddSeconds(90)
        } elseif (-not $engineSvc) {
            Log "WARN: no Docker engine service and Docker Desktop.exe not found at $dd"
        }
    } elseif (-not $reaped -and (Get-Date) -gt $graceEnd) {
        # Present but silent past the grace window => wedged, not starting.
        Log "Docker Desktop is running but the engine has not answered within the grace window -- treating it as wedged and restarting it once"
        Reset-DockerDesktop
        $reaped = $true
        $graceEnd = (Get-Date).AddSeconds(90)
        continue
    }

    Start-Sleep -Seconds 5
    if (-not $ready) { Log "Waiting for Docker engine..." }
}

if (-not $ready) {
    Log "ERROR: Docker engine did not become ready within $EngineWaitMinutes min."
    if (-not $interactive -and -not $engineSvc) {
        Log "CAUSE: this task runs in session 0 and the only engine on this host is Docker Desktop, which"
        Log "       needs an interactive sign-in to start its WSL2 backend. Unattended boot CANNOT work in"
        Log "       this configuration -- it is not a transient failure and retrying will not help."
        Log "REMEDY (pick one, in order of preference):"
        Log "       1. Move the gateway to a Linux runtime (Docker Engine + systemd): a Hyper-V VM on"
        Log "          this host, or a separate Linux host. See ADR-029. Then boot needs no sign-in."
        Log "          NOTE: a native Windows docker service (Docker CE / Mirantis) is NOT a fix --"
        Log "          it runs Windows containers only, and every image here is linux/amd64."
        Log "       2. Enable automatic sign-in for the service account that owns Docker Desktop. The"
        Log "          At-Log-On trigger on this task then brings the stack up right after boot."
        Log "       3. Sign in to the server after each reboot; the At-Log-On trigger does the rest."
    }
    # Leave nothing wedged behind: the next attempt -- and any operator running
    # this script by hand from a real session -- must start from a clean slate.
    if ($launched -or (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Log "cleaning up so the next attempt starts clean"
        Reset-DockerDesktop
    }
    Log "=== 3DX Gateway autostart end (engine unavailable) ==="
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
