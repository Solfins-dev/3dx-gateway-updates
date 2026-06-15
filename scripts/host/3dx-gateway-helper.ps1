<#
.SYNOPSIS
3DX Gateway host updater (Apply Update helper) -- Windows port of
3dx-gateway-helper.sh.

.DESCRIPTION
Windows host counterpart of the Linux systemd-socket-activated helper.
Listens on TCP 127.0.0.1:5171, accepts a line-oriented JSON protocol matching
the .sh version 1:1, runs `docker compose pull && up -d` in the configured
install dir on APPLY.

The gateway Docker container reaches this helper via `host.docker.internal`
(Docker Desktop maps that DNS name to the host's bridge interface). Auth is
a bearer token shared between the helper (stored on disk at
%PROGRAMDATA%\3dx-gateway\helper-token.txt) and the container (passed via
the HELPER_TOKEN env var, see docker-compose.helper-windows.yml).

Protocol (one command per TCP connection, both sides close after one
exchange):
  <command> <token>\n  -> json response\n

Where <command> in PING / STATUS / APPLY. The token MUST match the file
contents or the response is {"error":"unauthorized"}.

PING     -> {"ok":true,"helperVersion":"1.0.0"}
STATUS   -> {"stage":"idle|pulling|restarting|done|error", ...}
APPLY    -> kicks off background docker compose pull + up -d, returns
            {"started":true,"at":"<iso>"} immediately

Status file is written by the background apply worker to
%PROGRAMDATA%\3dx-gateway\status.json -- the backend polls STATUS to learn
progress.

.PARAMETER InstallDir
The 3DX Gateway install dir (where docker-compose.yml lives). Default:
%PROGRAMDATA%\3DX-Gateway.

.PARAMETER ComposeFiles
Space-separated list of compose files to apply. Default: docker-compose.yml.

.PARAMETER Port
TCP port to listen on. Default: 5171.

.PARAMETER BindAddress
IP address to bind to. Default: 0.0.0.0 (Docker host bridge needs to reach
this; 127.0.0.1 would not be reachable from inside the container).
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramData\3DX-Gateway",
    [string]$ComposeFiles = "docker-compose.yml",
    [int]$Port = 5171,
    [string]$BindAddress = "0.0.0.0"
)

$ErrorActionPreference = 'Stop'

$HelperVersion = '1.2.0'
$StateDir = "$env:ProgramData\3dx-gateway"
$StatusFile = "$StateDir\status.json"
$LogFile = "$StateDir\last-apply.log"
$TokenFile = "$StateDir\helper-token.txt"
$SetFile = "$StateDir\compose-set.json"
# The apply worker is a real .ps1 (forked with -File) copied next to this helper by
# install-helper.ps1. Falls back to the script's own dir when run in-place from the repo.
$WorkerScript = Join-Path $StateDir 'apply-worker.ps1'
if (-not (Test-Path $WorkerScript)) { $WorkerScript = Join-Path $PSScriptRoot 'apply-worker.ps1' }
# A non-terminal status older than this (and whose worker process is gone) is rewritten
# to error by the STATUS watchdog so the UI can never spin on "pulling" forever.
$ApplyHardCapMinutes = 30

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}

if (-not (Test-Path $TokenFile)) {
    throw "Token file $TokenFile not found. Run install-helper.ps1 first to generate one."
}

# Token self-heal: re-read the token from disk on every command (cheap — cached by the file's
# last-write-time) instead of capturing it once at startup. A token rotation by install-helper.ps1
# then takes effect IMMEDIATELY, even if an older helper process is still the one answering on
# port 5171 — this eliminates the "stale process answers with the OLD token -> unauthorized ->
# one-click update not available" failure the capture-at-startup design suffered (delmiaworks04, 2026-06-12).
$script:TokenCache = $null
$script:TokenCacheStamp = $null
function Get-CurrentToken {
    if (-not (Test-Path $TokenFile)) { return $script:TokenCache }
    try {
        $stamp = (Get-Item $TokenFile).LastWriteTimeUtc
        if ($script:TokenCache -and $script:TokenCacheStamp -eq $stamp) { return $script:TokenCache }
        $t = (Get-Content -Path $TokenFile -Raw -Encoding UTF8).Trim()
        if ($t) { $script:TokenCache = $t; $script:TokenCacheStamp = $stamp }
        return $t
    } catch {
        # Transient read race (e.g. mid-rotation) — fall back to the last good token.
        return $script:TokenCache
    }
}

if (-not (Get-CurrentToken)) {
    throw "Token file $TokenFile is empty. Re-run install-helper.ps1."
}

function Write-StatusFile {
    param([string]$Content)
    # Atomic write so STATUS reads never see a half-written file. No-BOM UTF8 (matching
    # the worker): Set-Content -Encoding UTF8 emits a BOM on PS5.1, and although STATUS
    # re-reads + re-sends over the no-BOM TCP writer (so the BOM wouldn't reach the
    # backend today), writing clean bytes here keeps the file itself parseable by any
    # consumer and removes the foot-gun entirely.
    $tmp = "$StatusFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $StatusFile -Force
}

function Get-NowIso { (Get-Date).ToUniversalTime().ToString('o') }

function Escape-Json {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return $s.Replace('\', '\\').Replace('"', '\"')
}

function Start-ApplyJob {
    # Mark "pulling" BEFORE forking so a fast STATUS poll right after APPLY
    # never sees "idle". The worker immediately overwrites this with its own PID +
    # start ticks so the STATUS watchdog can detect a dead worker.
    Write-StatusFile "{`"stage`":`"pulling`",`"startedAt`":`"$(Get-NowIso)`"}"

    if (-not (Test-Path $WorkerScript)) {
        Write-StatusFile "{`"stage`":`"error`",`"finishedAt`":`"$(Get-NowIso)`",`"error`":`"apply-worker.ps1 not found next to the helper -- re-run install.ps1 -AddHelper`"}"
        return
    }

    # Fork the worker as a real -File script (no inline -Command here-string, so there
    # is no nested-escaping surface and the worker's try/finally can guarantee a
    # terminal status). Build a single quoted arg line because ComposeFiles + paths
    # contain spaces and Start-Process -ArgumentList does not quote array elements.
    $argLine = @(
        '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$WorkerScript`"",
        '-StateDir', "`"$StateDir`"",
        '-FallbackInstallDir', "`"$InstallDir`"",
        '-FallbackComposeFiles', "`"$ComposeFiles`"",
        '-StepTimeoutSec', '1200'
    ) -join ' '

    # Detach via Start-Process so this handler can return immediately. The child
    # process gets its own hidden console and survives our exit.
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
}

# Watchdog: a non-terminal status whose worker process is gone (PID absent, or PID
# reused by a different process per StartTime), or that is older than the hard cap,
# is rewritten to error. Guarantees STATUS never reports "pulling"/"restarting"
# forever even if the worker was hard-killed before its finally{} ran.
function Get-StatusWithWatchdog {
    if (-not (Test-Path $StatusFile)) { return '{"stage":"idle"}' }
    $raw = (Get-Content -Path $StatusFile -Raw -Encoding UTF8).Trim()
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { return $raw }
    $stage = [string]$obj.stage
    if ($stage -ne 'pulling' -and $stage -ne 'restarting') { return $raw }

    $workerDead = $true
    if ($obj.workerPid) {
        try {
            $p = Get-Process -Id ([int]$obj.workerPid) -ErrorAction Stop
            # Defeat PID reuse: the live process must match the recorded start ticks.
            # Compare as STRINGS — the worker writes ticks as a string and process ticks
            # are ~18 digits, so any numeric coercion (double) would lose precision and
            # false-mismatch. A missing/"0" tick value means "not reliably recorded" →
            # don't use the tick check (rely on PID existence + the time cap).
            $recorded = [string]$obj.workerStartTicks
            if (-not $recorded -or $recorded -eq '0' -or $p.StartTime.Ticks.ToString() -eq $recorded) {
                $workerDead = $false
            }
        } catch { $workerDead = $true }
    } else {
        # No PID recorded yet (the pre-fork placeholder). Don't kill it on PID alone;
        # rely on the time cap below.
        $workerDead = $false
    }

    $tooOld = $false
    if ($obj.startedAt) {
        try {
            $age = (Get-Date).ToUniversalTime() - ([datetime]$obj.startedAt).ToUniversalTime()
            if ($age.TotalMinutes -ge $ApplyHardCapMinutes) { $tooOld = $true }
        } catch { }
    }

    if ($workerDead -or $tooOld) {
        $reason = if ($workerDead) { 'apply worker exited without completing' } else { "apply exceeded $ApplyHardCapMinutes min" }
        $err = "{`"stage`":`"error`",`"finishedAt`":`"$(Get-NowIso)`",`"error`":`"$reason -- see last-apply.log`",`"logPath`":`"$($LogFile -replace '\\','\\\\')`"}"
        Write-StatusFile $err
        return $err
    }
    return $raw
}

# DIAG: token-authed self-diagnosis the backend can surface instead of an opaque
# "not available". Built with ConvertTo-Json so the log tail (Windows paths, quotes,
# control chars) is always validly escaped.
function Get-DiagJson {
    $diag = [ordered]@{ helperVersion = $HelperVersion }

    # Resolve docker + engine reachability the same way the worker does.
    $docker = $null
    $cand = @((Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'))
    if (${env:ProgramFiles(x86)}) { $cand += (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\resources\bin\docker.exe') }
    foreach ($c in $cand) { if ($c -and (Test-Path $c)) { $docker = $c; break } }
    if (-not $docker) { $g = Get-Command docker -ErrorAction SilentlyContinue; if ($g) { $docker = $g.Source } }
    $diag.dockerPath = if ($docker) { $docker } else { 'not found' }
    if ($docker) {
        try { $sv = (& $docker version --format '{{.Server.Version}}' 2>$null); $diag.engine = if ($LASTEXITCODE -eq 0 -and $sv) { "reachable ($sv)" } else { 'unreachable as SYSTEM' } } catch { $diag.engine = 'unreachable' }
    }

    # Authoritative compose set.
    if (Test-Path $SetFile) {
        try { $diag.composeSet = (Get-Content $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $diag.composeSet = "unreadable: $($_.Exception.Message)" }
    } else { $diag.composeSet = 'absent' }

    # Live container labels (drift check). JSON format avoids the embedded-quote bug.
    if ($docker) {
        try {
            $lj = & $docker inspect --format '{{json .Config.Labels}}' '3dx-gateway-app' 2>$null
            if ($LASTEXITCODE -eq 0 -and $lj) {
                $lbl = $lj | ConvertFrom-Json
                $diag.liveLabels = [ordered]@{
                    config_files = $lbl.'com.docker.compose.project.config_files'
                    working_dir  = $lbl.'com.docker.compose.project.working_dir'
                    project      = $lbl.'com.docker.compose.project'
                    image        = (& $docker inspect --format '{{.Config.Image}}' '3dx-gateway-app' 2>$null)
                }
            } else { $diag.liveLabels = 'app container not found' }
        } catch { $diag.liveLabels = "inspect failed: $($_.Exception.Message)" }
    }

    if (Test-Path $StatusFile) {
        try { $diag.lastStatus = (Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    if (Test-Path $LogFile) {
        try { $diag.logTail = (Get-Content $LogFile -Tail 30 -Encoding UTF8) -join "`n" } catch { }
    }

    return ($diag | ConvertTo-Json -Depth 6 -Compress)
}

function Invoke-HelperCommand {
    param([string]$Line)

    $parts = $Line -split ' ', 2
    $cmd = if ($parts.Length -gt 0) { $parts[0].Trim() } else { '' }
    $providedToken = if ($parts.Length -gt 1) { $parts[1].Trim() } else { '' }

    # PING + STATUS could be read-only-no-auth, but for simplicity require the token on every
    # command. Re-read it fresh (self-heal) so a rotated token is honored immediately even by a
    # lingering older process.
    $currentToken = Get-CurrentToken
    if (-not $currentToken -or $providedToken -ne $currentToken) {
        return '{"error":"unauthorized"}'
    }

    switch ($cmd) {
        'PING' {
            return "{`"ok`":true,`"helperVersion`":`"$HelperVersion`"}"
        }
        'STATUS' {
            return (Get-StatusWithWatchdog)
        }
        'DIAG' {
            try { return (Get-DiagJson) }
            catch {
                $esc = Escape-Json $_.Exception.Message
                return "{`"helperVersion`":`"$HelperVersion`",`"error`":`"$esc`"}"
            }
        }
        'APPLY' {
            try {
                Start-ApplyJob
                return "{`"started`":true,`"at`":`"$(Get-NowIso)`"}"
            } catch {
                $esc = Escape-Json $_.Exception.Message
                return "{`"started`":false,`"error`":`"$esc`",`"at`":`"$(Get-NowIso)`"}"
            }
        }
        '' {
            return '{"error":"empty command"}'
        }
        default {
            $esc = Escape-Json $cmd
            return "{`"error`":`"unknown command`",`"received`":`"$esc`"}"
        }
    }
}

#--- Main listener loop -----------------------------------------------------

$ip = [System.Net.IPAddress]::Parse($BindAddress)

# Outer resilience loop: if the listener ever throws fatally (e.g. the port was transiently held
# by a not-yet-exited predecessor, or a socket error), log it and rebind after a short delay
# instead of letting the process exit. Combined with the token self-heal above, the helper stays
# reachable across reinstalls/token rotations without depending on a perfectly clean restart.
while ($true) {
  $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
  try {
    $listener.Start()
    Write-Host "3dx-gateway-helper.ps1 v$HelperVersion listening on $BindAddress`:$Port"
    Write-Host "  install dir:   $InstallDir"
    Write-Host "  compose files: $ComposeFiles"
    Write-Host "  state dir:     $StateDir"
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.NoDelay = $true
            $client.SendTimeout = 5000
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
            # No-BOM UTF8 for the writer: [System.Text.Encoding]::UTF8 emits a leading BOM (EF BB BF)
            # on every response, which the backend's System.Text.Json rejects with
            # "'0xEF' is an invalid start of a value" -> the gateway reports the helper as
            # unavailable even though it answered correctly (delmiaworks04, 2026-06-13).
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
            $writer.NewLine = "`n"
            $line = $reader.ReadLine()
            if ($null -eq $line) { continue }
            $response = Invoke-HelperCommand -Line $line
            $writer.WriteLine($response)
            $writer.Flush()
        } catch {
            # Per-connection errors must NOT kill the listener.
            Write-Warning "Connection handler error: $($_.Exception.Message)"
        } finally {
            try { $client.Close() } catch { }
        }
    }
  } catch {
    Write-Warning "Listener error on ${BindAddress}:${Port} -- rebinding in 2s: $($_.Exception.Message)"
    Start-Sleep -Seconds 2
  } finally {
    try { $listener.Stop() } catch { }
  }
}
