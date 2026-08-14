<#
.SYNOPSIS
3DX Gateway -- autostart setup / audit for Windows + Docker Desktop.

.DESCRIPTION
Run this on the gateway server (elevated) to make the Docker stack come up
automatically after a reboot, without an interactive Docker Desktop sign-in.
Run it with -CheckOnly any time to audit what is actually registered.

Why this is needed: on a Windows host the Docker engine is provided by Docker
Desktop (WSL2 Linux engine). Docker Desktop does NOT start on its own after a
reboot, so the gateway containers never come up and https://<host>/ hangs on
:443 (Caddy not listening). The compose services already carry
`restart: unless-stopped`, so they self-heal once the engine is up -- the only
missing piece is starting the engine at boot.

What it does:
  1. Writes the boot script to <InstallDir>\host\start-3dx-stack.ps1 (copies
     the sibling start-3dx-stack.ps1 if present, else writes an embedded copy).
  2. Registers the "3DX Gateway Autostart" Scheduled Task (triggers: at system
     startup, at log on, plus a retry repetition; highest privileges).
  3. Stamps the autostart CONTRACT: a version marker in the task description
     plus <InstallDir>\host\autostart-contract.json, so a later run -- or the
     boot script itself -- can tell a current registration from a stale one.
  4. Reports whether Docker Desktop is allowed to update itself, and pins that
     off with -DisableDockerAutoUpdate.

Why the contract exists (2026-08-10 post-mortem): the At-Log-On trigger and the
retry repetition were added to THIS file on 2026-08-07, but the task registered
on the customer's server still had a lone boot trigger, LastTaskResult=1 and an
empty NextRunTime. Delivering a script is not the same act as registering a
task; for five weeks nothing compared the two, and the gateway was dark for 36
hours before a human noticed. Everything below exists so that gap is visible
without anyone having to think of looking.

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

.PARAMETER CheckOnly
Change NOTHING. Compare the task that is registered right now against the task
this script would register today, print every match and mismatch, then exit.
Same switch name and same spirit as setup-cert-watchdog.ps1 / check-tls-cert.ps1.
Exit codes:
  0  registration matches the current contract
  1  registered, but drifted from the current contract
  2  no such scheduled task on this host
  3  the task could not be queried at all

.PARAMETER DisableDockerAutoUpdate
Write C:\ProgramData\DockerDesktop\admin-settings.json with
disableUpdate = { locked: true, value: true }, preserving any other keys already
in that file and backing the old one up. Without this switch the current state is
only REPORTED, never changed. See the caveats printed by the script: the
admin-settings.json mechanism is Docker's documented Settings Management channel
and its enforcement depends on the Docker subscription in use on the host, so
always confirm the result in the Docker Desktop UI afterwards.

.EXAMPLE
PS> .\setup-autostart.ps1 -CheckOnly
# Audit only -- safe on a running production host, touches nothing.

.EXAMPLE
PS> .\setup-autostart.ps1 -DisableDockerAutoUpdate
# Registers the task as the current user (prompts for password), pins Docker
# Desktop auto-update off, then verify:
PS> Start-ScheduledTask -TaskName '3DX Gateway Autostart'
PS> Get-Content C:\ProgramData\3DX-Gateway\autostart.log -Tail 40
#>

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\ProgramData\3DX-Gateway',
    [string]$TaskName   = '3DX Gateway Autostart',
    [string]$RunAsUser  = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$UseSystem,
    [string]$BootDelay  = 'PT1M',
    [int]$RetryMinutes  = 10,
    [switch]$CheckOnly,
    [switch]$DisableDockerAutoUpdate
)

$ErrorActionPreference = 'Stop'

# --- The autostart contract version ------------------------------------------
# Bump this whenever the SHAPE of the registered task changes (triggers, action
# arguments, principal). The value is stamped into the task description and into
# <InstallDir>\host\autostart-contract.json, which is the only way a registration
# made months ago can be recognised as stale rather than merely "present".
#
# History:
#   1  (<= 2026-08-06) boot trigger only.
#   2  (2026-08-07)    + At-Log-On trigger, + retry repetition on the boot
#                      trigger. This is the version the customer's server never
#                      received; the whole point of the stamp.
#   3  (2026-08-10)    + -ComposeDir / -TaskName passed to the boot script (a
#                      non-default -InstallDir used to be silently ignored),
#                      + contract manifest + self-audit.
$ContractVersion = '3'

# --- Admin guard -------------------------------------------------------------
# -CheckOnly reads and writes nothing, so it must be usable by whoever is holding
# the pager, not only by someone who already got an elevated shell open.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $CheckOnly) {
        throw "Run this elevated (Run as Administrator)."
    }
    Write-Warning "Not elevated. -CheckOnly still works, but some task properties may read as blank."
}

# --- The boot script (embedded fallback) -------------------------------------
# GENERATED VERBATIM from scripts/host/start-3dx-stack.ps1 -- do not hand-edit.
# It is used only when that file is not found next to this script (a bare copy of
# setup-autostart.ps1 on a customer server). Keeping it a byte-for-byte copy is
# deliberate: the previous 'mirrors the logic of' copy is exactly the kind of
# duplicate that drifts, and the drifted half only ever runs on the machines
# nobody is watching.
$bootScript = @'
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
'@

# --- What this script would register today -----------------------------------
# Computed before any branch so -CheckOnly can compare against it without
# creating a single file.
$hostDir     = Join-Path $InstallDir 'host'
$startScript = Join-Path $hostDir 'start-3dx-stack.ps1'
$manifestPath = Join-Path $hostDir 'autostart-contract.json'

$psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command powershell).Source }

# -ComposeDir and -TaskName are passed explicitly. Until contract v3 they were
# not, so a non-default -InstallDir registered a task that quietly worked on
# C:\ProgramData\3DX-Gateway instead -- and the boot script could not audit its
# own task because it did not know its name.
$expectedArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$startScript`"" +
                " -ComposeDir `"$InstallDir`" -TaskName `"$TaskName`""

$expectedTriggerClasses = @('MSFT_TaskBootTrigger', 'MSFT_TaskLogonTrigger')
$expectedRepetition     = "PT${RetryMinutes}M"
$contractMarker         = "[3dx-autostart-contract v=$ContractVersion boot=$BootDelay retry=${RetryMinutes}m]"

# --- Audit helpers -----------------------------------------------------------
$script:Findings = @()
function Add-Finding([string]$level, [string]$text) {
    $script:Findings += [pscustomobject]@{ Level = $level; Text = $text }
}
function Show-Findings {
    foreach ($f in $script:Findings) {
        $c = switch ($f.Level) {
            'OK'    { 'Green' }
            'DRIFT' { 'Red' }
            'WARN'  { 'Yellow' }
            default { 'Gray' }
        }
        Write-Host ("  {0,-5}  {1}" -f $f.Level, $f.Text) -ForegroundColor $c
    }
}

# Compare the LIVE registration against the expectations computed above.
# Returns: 0 match, 1 drift, 2 missing, 3 unqueryable.
function Test-AutostartTask {
    $script:Findings = @()

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        # Distinguish "not there" from "cannot ask" -- they need different actions.
        $probe = $null
        try { $probe = Get-ScheduledTask -ErrorAction Stop | Select-Object -First 1 } catch { }
        if ($probe) {
            Add-Finding 'DRIFT' "Scheduled task '$TaskName' is NOT registered on this host."
            Add-Finding 'INFO'  "Nothing brings the stack up after a reboot. Register it: run this script without -CheckOnly."
            return 2
        }
        Add-Finding 'WARN' "Cannot query the Task Scheduler at all ($($_.Exception.Message))."
        return 3
    }

    $drift = 0

    # 1. Contract version stamped in the description.
    $regVer = ''
    if ($task.Description -and ($task.Description -match '3dx-autostart-contract\s+v=([^\s\]]+)')) {
        $regVer = $Matches[1]
    }
    if ($regVer -eq $ContractVersion) {
        Add-Finding 'OK' "Contract version v$regVer (current)."
    } elseif ($regVer) {
        Add-Finding 'DRIFT' "Contract version v$regVer registered, this script ships v$ContractVersion."
        $drift++
    } else {
        Add-Finding 'DRIFT' "No contract marker in the task description -- registered before 2026-08-10 (contract v1 or v2), shape unverifiable from the stamp alone."
        $drift++
    }

    # 2. Triggers. This is the exact item that was stale on the customer's server
    #    for five weeks: a lone MSFT_TaskBootTrigger, no logon trigger, no retry.
    $kinds = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
    Add-Finding 'INFO' "Registered triggers: $(if ($kinds.Count) { $kinds -join ', ' } else { '(none)' })"
    foreach ($want in $expectedTriggerClasses) {
        if ($kinds -contains $want) {
            Add-Finding 'OK' "Trigger $want present."
        } else {
            Add-Finding 'DRIFT' "Trigger $want MISSING."
            $drift++
        }
    }

    # 3. Retry repetition. Without it, one failed boot attempt is the last one.
    $rep = $null
    foreach ($t in $task.Triggers) {
        if ($t.Repetition -and $t.Repetition.Interval) { $rep = $t.Repetition.Interval; break }
    }
    if (-not $rep) {
        Add-Finding 'DRIFT' "No repeating trigger. A failed boot attempt is never retried (expected every $expectedRepetition)."
        $drift++
    } elseif ($rep -ne $expectedRepetition) {
        Add-Finding 'DRIFT' "Repetition is $rep, this script ships $expectedRepetition."
        $drift++
    } else {
        Add-Finding 'OK' "Retry repetition $rep."
    }

    # 4. Action: which script, with which arguments.
    if (-not $task.Actions -or $task.Actions.Count -eq 0) {
        Add-Finding 'DRIFT' "Task has no action at all."
        $drift++
    } else {
        $a = $task.Actions[0]
        if ($a.Execute -ne $psExe) {
            Add-Finding 'WARN' "Interpreter is '$($a.Execute)'; this script would use '$psExe'. Not fatal if both are a working PowerShell."
        } else {
            Add-Finding 'OK' "Interpreter $($a.Execute)."
        }
        if ($a.Arguments -eq $expectedArgs) {
            Add-Finding 'OK' "Action arguments match."
        } else {
            Add-Finding 'DRIFT' "Action arguments differ."
            Add-Finding 'INFO' "  registered: $($a.Arguments)"
            Add-Finding 'INFO' "  expected  : $expectedArgs"
            $drift++
        }
        # An action pointing at a script that is not on disk is a task that
        # cannot possibly work -- and it fails silently at boot.
        $m = [regex]::Match([string]$a.Arguments, '-File\s+"([^"]+)"')
        if ($m.Success -and -not (Test-Path $m.Groups[1].Value)) {
            Add-Finding 'DRIFT' "The boot script it points at does not exist: $($m.Groups[1].Value)"
            $drift++
        }
    }

    # 5. Principal. Only compared strictly when the caller actually stated what
    #    it should be; otherwise reported, because the account a task was
    #    registered with is a legitimate site decision, not drift.
    $p = $task.Principal
    Add-Finding 'INFO' "Runs as '$($p.UserId)' (LogonType=$($p.LogonType), RunLevel=$($p.RunLevel))."
    if ($p.RunLevel -ne 'Highest') {
        Add-Finding 'DRIFT' "RunLevel is $($p.RunLevel); the task needs Highest to start services."
        $drift++
    }
    if ($UseSystem) {
        if ($p.UserId -notmatch '(?i)^(SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18)$') {
            Add-Finding 'DRIFT' "-UseSystem was requested but the task runs as '$($p.UserId)'."
            $drift++
        }
    } elseif ($PSBoundParameters.ContainsKey('RunAsUser')) {
        if ($p.UserId -ne $RunAsUser) {
            Add-Finding 'DRIFT' "-RunAsUser '$RunAsUser' was requested but the task runs as '$($p.UserId)'."
            $drift++
        }
    }

    # 6. Enabled + last outcome. A disabled task and a task that failed months
    #    ago and never ran again both look identical to "registered".
    if ($task.State -eq 'Disabled') {
        Add-Finding 'DRIFT' "Task state is Disabled."
        $drift++
    } else {
        Add-Finding 'OK' "Task state $($task.State)."
    }
    # Pipe the task object rather than the name: -TaskName alone only resolves
    # tasks in the root folder, and silently finds nothing for a task someone
    # moved into a subfolder -- which would hide the very fields that matter.
    $info = $null
    try { $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
    if ($info) {
        Add-Finding 'INFO' "LastRunTime=$($info.LastRunTime)  LastTaskResult=$($info.LastTaskResult)  NextRunTime=$($info.NextRunTime)"
        if ($info.LastTaskResult -ne 0) {
            # The boot script exits 1 when the engine never came up. Task
            # Scheduler treats that as a clean process exit and does NOT apply
            # -RestartCount, so this can sit at 1 forever without a single retry.
            Add-Finding 'WARN' "Last run returned $($info.LastTaskResult) (non-zero). Read $(Join-Path $InstallDir 'autostart.log') for the reason."
        }
        if (-not $info.NextRunTime) {
            Add-Finding 'DRIFT' "NextRunTime is empty -- nothing is scheduled to run this task again. This is exactly the state the customer's server sat in from 2026-08-07 to 2026-08-10."
            $drift++
        }
    }

    # 7. The manifest the boot script audits itself against.
    if (Test-Path $manifestPath) {
        try {
            $mf = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$mf.contractVersion -eq $ContractVersion) {
                Add-Finding 'OK' "Contract manifest present and current ($manifestPath)."
            } else {
                Add-Finding 'DRIFT' "Contract manifest says v$($mf.contractVersion), this script ships v$ContractVersion."
                $drift++
            }
        } catch {
            Add-Finding 'WARN' "Contract manifest unreadable: $($_.Exception.Message)"
        }
    } else {
        Add-Finding 'DRIFT' "No contract manifest at $manifestPath -- the boot script cannot self-audit."
        $drift++
    }

    if ($drift -gt 0) { return 1 }
    return 0
}

# --- Docker Desktop auto-update state ----------------------------------------
# Root cause of the 36-hour outage that started 2026-08-08 20:02: Docker Desktop
# updated itself (System log 7034 "Docker Desktop Service terminated
# unexpectedly", then 7045 re-installing com.docker.service; engine went
# 29.5.3 -> 29.6.2). The engine died under the containers, so
# `restart: unless-stopped` had nothing to act on, and with nobody signed in the
# WSL2 backend could not come back on its own.
#
# WHAT IS VERIFIED (read out of the shipped Docker Desktop binaries on a machine
# with Docker Desktop installed, 2026-08-10):
#   * "disableUpdate" is a real settings key -- it appears as the Go struct tag
#     DisableUpdate `json:"disableUpdate"` in Docker Desktop.exe, DockerCli.exe
#     and Docker.Core.dll, in the same lockable-settings struct as other admin
#     settings.
#   * "admin-settings.json" is a real Docker Desktop configuration filename --
#     it appears in Docker.Core.dll's filename table next to settings-store.json
#     and install-settings.json, and "--admin-settings=" is an accepted Docker
#     Desktop Installer.exe command-line flag.
#   * C:\ProgramData\DockerDesktop is the machine-wide config directory: the
#     sibling install-settings.json genuinely lives there.
#   * The per-user file %APPDATA%\Docker\settings-store.json exists and its
#     struct carries AutoDownloadUpdates `json:"autoDownloadUpdates"`. Keys are
#     omitted from that file while they hold their default value.
#
# WHAT IS **NOT** VERIFIED HERE:
#   * That writing disableUpdate actually blocks the updater on THIS host.
#     admin-settings.json is Docker's Settings Management channel and Docker
#     documents it as a Business-subscription feature; on a host that is not
#     signed in to such an organisation it may be ignored. Nobody has reproduced
#     a blocked update on delmiaworks04 yet.
#   * There is no registry policy for update control that I could confirm in the
#     shipped binaries, so this script does not write one. Guessing a key that
#     silently does nothing is worse than reporting honestly.
# Therefore: after applying this, CONFIRM in the Docker Desktop UI (Settings ->
# Software updates) that the option is greyed out, and treat the engine-service
# migration below as the only guaranteed fix.
$DockerAdminSettings = Join-Path $env:ProgramData 'DockerDesktop\admin-settings.json'

function Show-DockerUpdateState {
    Write-Host ""
    Write-Host "Docker Desktop auto-update state" -ForegroundColor Cyan
    Write-Host "--------------------------------"

    if (Test-Path $DockerAdminSettings) {
        try {
            $j = Get-Content -Path $DockerAdminSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.disableUpdate -and $j.disableUpdate.value -eq $true) {
                Write-Host "  admin-settings.json : disableUpdate value=true locked=$($j.disableUpdate.locked)" -ForegroundColor Green
            } else {
                Write-Host "  admin-settings.json : present, but disableUpdate is not value=true" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  admin-settings.json : UNREADABLE ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  admin-settings.json : absent ($DockerAdminSettings)" -ForegroundColor Yellow
        Write-Host "                        -> nothing stops Docker Desktop from updating itself."
    }

    # Per-user preference. Informational only: it is per profile, a user can flip
    # it back in the UI, and the machine-wide file is the one that is meant to
    # hold. Reported because it is the setting an operator will look at first.
    $store = Join-Path $env:APPDATA 'Docker\settings-store.json'
    if (Test-Path $store) {
        try {
            $s = Get-Content -Path $store -Raw -Encoding UTF8 | ConvertFrom-Json
            $has = $s.PSObject.Properties.Name -contains 'AutoDownloadUpdates'
            $val = if ($has) { $s.AutoDownloadUpdates } else { '(absent = Docker default)' }
            Write-Host "  settings-store.json : AutoDownloadUpdates = $val  [current user only: $env:USERNAME]"
        } catch {
            Write-Host "  settings-store.json : unreadable ($($_.Exception.Message))"
        }
    } else {
        Write-Host "  settings-store.json : absent for $env:USERNAME (this account has not run Docker Desktop)"
    }

    # Forensics: every past self-update leaves an installer log behind. This is
    # how a "does it really update itself?" argument gets settled with evidence.
    $logDir = Join-Path $env:ProgramData 'DockerDesktop'
    if (Test-Path $logDir) {
        $logs = @(Get-ChildItem -Path $logDir -Filter 'install-log-admin*.txt' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 4)
        if ($logs.Count -gt 0) {
            Write-Host "  past installs       : $(($logs | ForEach-Object { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }) -join ' | ')"
            Write-Host "                        (each entry is a Docker Desktop install/self-update on this host)"
        }
    }

    $ver = ''
    $ddExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (Test-Path $ddExe) {
        try { $ver = (Get-Item $ddExe).VersionInfo.ProductVersion } catch { }
        Write-Host "  Docker Desktop      : $ddExe $(if ($ver) { "(v$ver)" })"
    }
}

function Disable-DockerAutoUpdate {
    $dir = Split-Path -Parent $DockerAdminSettings
    if (-not (Test-Path $dir)) {
        Write-Host ""
        Write-Host "SKIPPED: $dir does not exist, so Docker Desktop is not installed the way this" -ForegroundColor Yellow
        Write-Host "         switch assumes. Refusing to create a config directory Docker may never read." -ForegroundColor Yellow
        return
    }

    # Merge, never clobber: an admin-settings.json placed here by someone else
    # may already carry proxy or sign-in policy for this host.
    $obj = $null
    if (Test-Path $DockerAdminSettings) {
        try {
            $obj = Get-Content -Path $DockerAdminSettings -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Host "ABORT: $DockerAdminSettings exists but is not valid JSON ($($_.Exception.Message))." -ForegroundColor Red
            Write-Host "       Fix or move it by hand; overwriting it could drop other policy on this host." -ForegroundColor Red
            return
        }
        $bak = "$DockerAdminSettings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $DockerAdminSettings -Destination $bak -Force
        Write-Host "Backed up existing admin-settings.json to $bak"
    }
    if (-not $obj) { $obj = New-Object psobject }

    if (-not ($obj.PSObject.Properties.Name -contains 'configurationFileVersion')) {
        Add-Member -InputObject $obj -MemberType NoteProperty -Name 'configurationFileVersion' -Value 2
    }
    $lock = [pscustomobject]@{ locked = $true; value = $true }
    if ($obj.PSObject.Properties.Name -contains 'disableUpdate') {
        $obj.disableUpdate = $lock
    } else {
        Add-Member -InputObject $obj -MemberType NoteProperty -Name 'disableUpdate' -Value $lock
    }

    # No BOM: Docker's JSON parser is Go's encoding/json, which rejects a
    # UTF-8 BOM. Set-Content -Encoding UTF8 on PS 5.1 writes one.
    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($DockerAdminSettings, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $DockerAdminSettings with disableUpdate = { locked: true, value: true }" -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT -- verify, do not assume:" -ForegroundColor Yellow
    Write-Host "  * Docker Desktop reads this file at start-up: restart it (or reboot) for it to take effect."
    Write-Host "  * Then open Docker Desktop -> Settings -> Software updates and confirm the update option"
    Write-Host "    is greyed out / says it is managed. Docker documents Settings Management as a Business"
    Write-Host "    subscription feature, so on a host without that entitlement this file may be IGNORED."
    Write-Host "    It has not been proven to hold on this server yet."
    Write-Host "  * The only mechanism that removes the risk outright is moving the gateway to a Linux"
    Write-Host "    runtime (Docker Engine + systemd) -- see ADR-029 -- which also fixes unattended boot."
    Write-Host "    A native Windows docker service (Docker CE / Mirantis) is NOT an option here: it"
    Write-Host "    runs Windows containers only, and every image in this stack is linux/amd64."
    Write-Host "  * This is a file on disk, so it survives reboots with no manual step."
}

# --- -CheckOnly: audit and get out -------------------------------------------
if ($CheckOnly) {
    Write-Host ""
    Write-Host "3DX Gateway autostart -- audit only, nothing is being changed." -ForegroundColor Cyan
    Write-Host "Task     : $TaskName"
    Write-Host "Contract : v$ContractVersion (this script)"
    Write-Host ""
    $rc = Test-AutostartTask
    Show-Findings
    Write-Host ""
    switch ($rc) {
        0 { Write-Host "RESULT: the registered task matches the current autostart contract." -ForegroundColor Green }
        1 { Write-Host "RESULT: DRIFT -- the registered task is not what this script ships." -ForegroundColor Red
            Write-Host "        Re-register (elevated):  .\setup-autostart.ps1" -ForegroundColor Red }
        2 { Write-Host "RESULT: the autostart task is NOT registered on this host." -ForegroundColor Red
            Write-Host "        Register it (elevated):  .\setup-autostart.ps1" -ForegroundColor Red }
        default { Write-Host "RESULT: could not audit the task." -ForegroundColor Yellow }
    }
    Show-DockerUpdateState
    Write-Host ""
    exit $rc
}

# --- 0. Say what is there BEFORE we replace it -------------------------------
# The old code went straight to Unregister-ScheduledTask, so a five-week-old
# registration was destroyed without anyone ever learning it had been wrong.
Write-Host ""
Write-Host "Current registration (before changes):" -ForegroundColor Cyan
$preRc = Test-AutostartTask
Show-Findings
if ($preRc -eq 1) {
    Write-Host "  -> drift found; it is being corrected now." -ForegroundColor Yellow
} elseif ($preRc -eq 2) {
    Write-Host "  -> not registered; registering now." -ForegroundColor Yellow
}
Write-Host ""

# --- 1. Write the boot script ------------------------------------------------
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null

$sibling = Join-Path $PSScriptRoot 'start-3dx-stack.ps1'
if ((Test-Path $sibling) -and ((Resolve-Path $sibling).Path -ne $startScript)) {
    Copy-Item -Path $sibling -Destination $startScript -Force
    Write-Host "Copied boot script from $sibling"
} else {
    Set-Content -Path $startScript -Value $bootScript -Encoding ASCII
    Write-Host "Wrote embedded boot script to $startScript"
}

# Put a copy of THIS script next to the boot script too, so the audit can be run
# on the server without hunting for the repo -- the customer server is exactly
# where nobody has the repo checked out.
try {
    $selfDest = Join-Path $hostDir 'setup-autostart.ps1'
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $selfDest)) {
        Copy-Item -Path $PSCommandPath -Destination $selfDest -Force
        Write-Host "Copied this setup script to $selfDest (for later -CheckOnly runs)"
    }
} catch {
    Write-Warning "Could not copy setup-autostart.ps1 next to the boot script: $($_.Exception.Message)"
}

# --- 2. Register the Scheduled Task ------------------------------------------
$action = New-ScheduledTaskAction -Execute $psExe -Argument $expectedArgs

# --- Triggers ----------------------------------------------------------------
# THREE triggers, because one is provably not enough on a Docker Desktop host.
#
#   AtStartup  - the unattended path. Works when the engine is a real Windows
#                service; on a Docker-Desktop-only host it runs in session 0
#                where Desktop's WSL2 backend cannot initialise, and the boot
#                script says so in one line instead of timing out silently.
#   AtLogOn    - the path that actually recovers a Docker Desktop host. Docker
#                Desktop needs an interactive sign-in anyway, so the moment an
#                admin signs in after a reboot the stack comes up on its own --
#                nobody has to remember to run a script. This is the trigger
#                that was missing on 2026-08-07, when the server sat dark until
#                someone noticed and brought it up by hand.
#   Repetition - every $RetryMinutes, indefinitely. This is the one that would
#                have contained the 2026-08-08 outage: Docker Desktop updated
#                itself and killed the engine mid-day, which is not a boot event
#                and not a log-on event, so only a periodic run can notice. An
#                already-healthy stack makes `compose up -d` a no-op, so the
#                retry is nearly free.
$tBoot = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = $BootDelay   # ISO-8601 duration, e.g. PT1M = 1 minute

$tLogon = New-ScheduledTaskTrigger -AtLogOn
$tLogon.Delay = 'PT30S'

# Indefinite repetition. PS 5.1 needs the [TimeSpan]::MaxValue idiom and some
# builds reject it, so fall back to a 10-year duration (indefinite in practice,
# and the idiom setup-cert-watchdog.ps1 already uses) rather than failing the
# whole install over a retry cadence.
$repAttached = $false
try {
    $tBoot.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $RetryMinutes) `
        -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
    $repAttached = $true
} catch {
    try {
        $tBoot.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $RetryMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
        $repAttached = $true
    } catch {
        Write-Warning "Could not attach a repeating trigger ($($_.Exception.Message)); boot + logon triggers only."
    }
}
# The repetition used to hang off the boot trigger alone: if that trigger ever
# failed to fire, the retry went with it. Mirror it onto the logon trigger too,
# so the two paths fail independently.
if ($repAttached) {
    try { $tLogon.Repetition = $tBoot.Repetition } catch { }
}

# IgnoreNew: the repetition must never stack a second run on top of one that is
# still waiting out the engine timeout.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 2)

$description = "3DX Gateway autostart. $contractMarker " +
               "Registered $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $env:USERNAME. " +
               "Do not edit by hand -- re-run scripts/host/setup-autostart.ps1; audit with -CheckOnly."

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
        -Trigger $tBoot,$tLogon -Settings $settings -Principal $principal `
        -Description $description | Out-Null
    $registeredAs = 'SYSTEM'
} else {
    Write-Host "Registering '$TaskName' to run as $RunAsUser (run whether logged on or not)..."
    $cred = Get-Credential -UserName $RunAsUser `
        -Message "Password for $RunAsUser (stored by Windows so the task runs at boot)"
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $tBoot,$tLogon -Settings $settings `
        -User $cred.UserName `
        -Password $cred.GetNetworkCredential().Password `
        -RunLevel Highest -Description $description | Out-Null
    $registeredAs = $cred.UserName
}

# --- 3. Stamp the contract manifest ------------------------------------------
# This file is what the boot script audits itself against on every run, so a
# registration that gets edited or replaced later is reported in autostart.log
# instead of waiting for someone to run this script again.
$manifest = [pscustomobject]@{
    contractVersion   = $ContractVersion
    taskName          = $TaskName
    execute           = $psExe
    actionArguments   = $expectedArgs
    triggerClasses    = $expectedTriggerClasses
    repetitionInterval= $expectedRepetition
    bootDelay         = $BootDelay
    registeredAs      = $registeredAs
    registeredAtUtc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    registeredBy      = "$env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
    installDir        = $InstallDir
}
$mfJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $mfJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Stamped autostart contract v$ContractVersion to $manifestPath"

# --- 4. Verify what we just registered ---------------------------------------
# Registering and believing it worked is precisely the habit that produced a
# five-week drift. Read it back.
Write-Host ""
Write-Host "Verifying the registration that was just written:" -ForegroundColor Cyan
$postRc = Test-AutostartTask
Show-Findings
Write-Host ""
if ($postRc -eq 0) {
    Write-Host "Registration verified against contract v$ContractVersion." -ForegroundColor Green
} else {
    # NextRunTime can legitimately be blank for a moment right after
    # registration, so this is a warning to re-check, not a failure.
    Write-Host "WARNING: the readback above does not fully match the contract." -ForegroundColor Yellow
    Write-Host "         Re-run '.\setup-autostart.ps1 -CheckOnly' in a minute; if it still reports drift," -ForegroundColor Yellow
    Write-Host "         the task did not register the way this script intended -- do not trust the autostart." -ForegroundColor Yellow
}

# --- 5. Engine verdict -------------------------------------------------------
# Say up front whether THIS host can actually come up unattended. These scripts
# make every recoverable case recover, but no script can start Docker Desktop's
# WSL2 backend without an interactive session -- and an operator who is not told
# that will keep believing a reboot is safe when it is not.
$engineSvc  = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
$ddPath     = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$hasDesktop = Test-Path $ddPath

Write-Host ""
if ($engineSvc) {
    Write-Host "Engine: Docker Engine Windows service ('docker') detected." -ForegroundColor Green
    Write-Host "        This host CAN start the gateway after a reboot with nobody signed in."
} elseif ($hasDesktop) {
    Write-Host "Engine: Docker Desktop only -- no 'docker' Windows service on this host." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This host CANNOT bring the gateway up after a reboot unless somebody signs in." -ForegroundColor Yellow
    Write-Host "  Docker Desktop's WSL2 backend needs an interactive session; a boot-time task runs"
    Write-Host "  in session 0, where it cannot start. That is a property of Docker Desktop, not a"
    Write-Host "  bug in these scripts, and no amount of retrying changes it."
    Write-Host ""
    Write-Host "  What IS handled now: the At-Log-On trigger brings the stack up the moment an admin"
    Write-Host "  signs in, the boot script reaps a wedged Docker Desktop instead of waiting on it"
    Write-Host "  forever, and the retry trigger recovers a transient engine failure on its own."
    Write-Host ""
    Write-Host "  To make reboots fully unattended, pick one:" -ForegroundColor Yellow
    Write-Host "    1. Move the gateway to a Linux runtime (Docker Engine + systemd) -- a Hyper-V VM"
    Write-Host "       on this host, or a separate Linux host. See ADR-029. This also retires the"
    Write-Host "       Docker Desktop licence question. A native Windows docker service (Docker CE /"
    Write-Host "       Mirantis) is NOT a fix: it runs Windows containers only."
    Write-Host "    2. Enable automatic sign-in for the account that owns Docker Desktop."
} else {
    Write-Host "Engine: NO Docker engine found (neither a 'docker' service nor Docker Desktop)." -ForegroundColor Red
    Write-Host "        Install one before relying on this task."
}

# --- 6. Docker Desktop auto-update -------------------------------------------
Show-DockerUpdateState
if ($DisableDockerAutoUpdate) {
    Disable-DockerAutoUpdate
} else {
    Write-Host ""
    Write-Host "  Not changed (reporting only). To pin auto-update off:" -ForegroundColor Yellow
    Write-Host "    .\setup-autostart.ps1 -DisableDockerAutoUpdate"
    Write-Host "  On 2026-08-08 20:02 a Docker Desktop self-update terminated the engine service and the"
    Write-Host "  gateway stayed down for 36 hours. An update that reinstalls the engine is not something"
    Write-Host "  'restart: unless-stopped' can survive."
}

Write-Host ""
Write-Host "Done. Task registered with boot + logon triggers and a $RetryMinutes-minute retry." -ForegroundColor Green
Write-Host ""
Write-Host "Test it now without rebooting:"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Start-Sleep 20"
Write-Host "  Get-Content '$(Join-Path $InstallDir 'autostart.log')' -Tail 40"
Write-Host "  (Test-NetConnection -ComputerName localhost -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded"
Write-Host ""
Write-Host "NOTE: port 80 on this host is answered by IIS (Microsoft-IIS/10.0), NOT by this stack."
Write-Host "      Never conclude the gateway is up because :80 replies. Test :443 (and :8081)."
Write-Host ""
Write-Host "Audit any time, changes nothing:  .\setup-autostart.ps1 -CheckOnly"
Write-Host "Remove later with:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
