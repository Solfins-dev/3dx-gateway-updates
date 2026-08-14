<#
.SYNOPSIS
3DX Gateway -- one-shot setup for the TLS / health watchdog.

.DESCRIPTION
Self-contained. Run this ONCE on the gateway server (elevated) to register a
Scheduled Task that keeps the Caddy TLS certificate healthy AND raises a loud,
human-visible alarm when the gateway is down.

Why the certificate half is needed: Caddy's `tls internal` leaf certificates
live 12 hours and are auto-renewed -- but only while Caddy can read and write
its storage volume. On Windows that volume lives inside Docker Desktop's WSL2
VHDX, which Windows tears down without a graceful container stop on power loss
AND on ordinary Windows Update reboots. When that loses the leaf's private key,
Caddy keeps serving the certificate it already holds in memory (site stays up,
app answers 200) while every renewal fails -- and roughly 8 hours later the
cached certificate expires and every browser shows "Not secure". On
delmiaworks04 that state went unnoticed for 23 days because the only signal was
a log line.

Why the alarm half is needed: on 2026-08-08 Docker Desktop updated itself and
killed its own service. The ENGINE went away, not a container -- so
`restart: unless-stopped` was powerless -- and nobody was signed in, so the
WSL2 backend could not come back on its own. The stack was dark for 36 hours.
The watchdog detected it NINE times and deliberately did nothing each time,
because its only output was a line in a log file that nobody reads, and it
blamed a Scheduled Task that had itself been failing since the previous day.

So this task now:
  * checks the certificate actually served on :443 and the key file backing it,
    and restarts Caddy when either is broken (unchanged behaviour);
  * classifies a dead gateway into "Docker engine gone" vs "Caddy container
    down" vs "container up but not serving", because those are different
    faults with different remedies;
  * writes a Windows Application event log entry (source '3DX Gateway',
    IDs 9000-9004) and <InstallDir>\GATEWAY-DOWN.txt so a human -- or any RMM
    agent that already watches the event log -- learns about it;
  * verifies, on every pass, that the '3DX Gateway Autostart' task it delegates
    recovery to still exists, is enabled, has a logon trigger and a repetition,
    and last exited 0 (read-only; it never modifies that task).

What this script does:
  1. Registers the '3DX Gateway' Windows event log source (so the SYSTEM task
     can write alarms without needing to create the source itself).
  2. Writes the check script to <InstallDir>\host\check-tls-cert.ps1 (copies
     the sibling check-tls-cert.ps1 if present, else writes an embedded copy).
  3. Registers the "3DX Gateway TLS Watchdog" Scheduled Task (runs as SYSTEM;
     10 min after startup + every -IntervalHours; highest privileges).
  4. Runs one -CheckOnly pass inline so you see the current state immediately.

Runs as SYSTEM deliberately: unlike the boot autostart task it never has to
start Docker Desktop (it only talks to an already-running engine), so it needs
no user profile and no stored password -- which also makes it safe to install
unattended.

ASCII-only on purpose (PS 5.1 misparses non-ASCII depending on host codepage).

.PARAMETER InstallDir
Compose install dir. Default: C:\ProgramData\3DX-Gateway

.PARAMETER IntervalHours
How often to check. Default 1 (was 4 until 2026-08-10). This is not a taste
setting -- see -MinHoursRemaining for the invariant it has to satisfy. Cheap
enough to run hourly: one TLS handshake, one `docker version`, one
`docker exec ls`, one read-only Scheduled Task query.

.PARAMETER MinHoursRemaining
Restart when the served leaf has less than this many hours left. Default 3
(was 2 until 2026-08-10).

Two invariants govern this pair, and this script refuses / warns when they are
violated:

  (a) MinHoursRemaining must stay BELOW ~3.83h. Caddy renews at two thirds of a
      12h leaf (i.e. with 4h left) and its maintenance loop runs every 600s, so
      a perfectly healthy system never drops below ~3.83h. A threshold at or
      above that alarms on healthy hosts and produces pointless restarts.

  (b) IntervalHours must be <= MinHoursRemaining / 2, so at least TWO checks
      fall inside the pre-emptive window -- the stretch where the certificate is
      still valid and no user has seen a warning yet. One missed cycle (task did
      not fire, engine momentarily unreachable) then still is not a visible
      outage.

The old 4h/2h pair violated (b) by a factor of four: a 2h window sampled every
4h is hit only half the time, and the worst case is exactly
IntervalHours - MinHoursRemaining = 2h of "Not secure" in every browser. The
1h/3h pair gives three samples before expiry and a worst case of 0h.

.EXAMPLE
PS> .\setup-cert-watchdog.ps1
# Registers the task, then verify:
PS> Start-ScheduledTask -TaskName '3DX Gateway TLS Watchdog'
PS> Get-Content C:\ProgramData\3DX-Gateway\autostart.log -Tail 40
#>

[CmdletBinding()]
param(
    [string]$InstallDir         = 'C:\ProgramData\3DX-Gateway',
    [string]$TaskName           = '3DX Gateway TLS Watchdog',
    [string]$CaddyContainer     = '3dx-gateway-caddy',
    [int]$IntervalHours         = 1,
    [int]$MinHoursRemaining     = 3,
    # The task this watchdog delegates recovery to, and now verifies.
    [string]$AutostartTaskName  = '3DX Gateway Autostart',
    [string]$EventSource        = '3DX Gateway',
    [int]$MaxRecoveryAttempts   = 3,
    [int]$RecoveryCooldownHours = 6,
    # The autostart-task fault is logged every pass but raised as event 9004 at
    # most this often (hourly checks would otherwise mean 24 identical events a
    # day until somebody re-runs setup-autostart.ps1).
    [int]$DelegateAlarmEveryHours = 12,
    # Escape hatch: register the task with -NoRecover, i.e. alarm and classify
    # but never attempt any repair.
    [switch]$NoRecover,
    # Skip the invariant guard below (you had better have a reason).
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Admin guard -------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this elevated (Run as Administrator)."
}

# --- Cadence invariants (see .PARAMETER MinHoursRemaining) -------------------
# Encoded, not merely documented: the 2026-08-08 post-mortem found the pair had
# drifted into a structurally under-sampling configuration and nothing objected.
$healthyFloorHours = 3.83   # 4h renewal point minus one 600s maintenance cycle
if ($MinHoursRemaining -ge $healthyFloorHours) {
    $msg = "MinHoursRemaining=$MinHoursRemaining is at or above the healthy floor (~${healthyFloorHours}h). " +
           "Caddy renews with 4h left, so this threshold fires on a HEALTHY system and causes pointless restarts. Use 2 or 3."
    if ($Force) { Write-Warning "$msg (-Force given, continuing)" } else { throw $msg }
}
$maxInterval = [math]::Floor($MinHoursRemaining / 2)
if ($maxInterval -lt 1) { $maxInterval = 1 }
if ($IntervalHours -gt $maxInterval) {
    $msg = "IntervalHours=$IntervalHours under-samples MinHoursRemaining=$MinHoursRemaining. " +
           "At most $maxInterval h is allowed (>= 2 checks inside the pre-emptive window); " +
           "worst-case user-visible 'Not secure' exposure with your values is " +
           "$($IntervalHours - $MinHoursRemaining) h."
    if ($Force) { Write-Warning "$msg (-Force given, continuing)" } else { throw $msg }
}
Write-Host ("Cadence: every {0}h, threshold {1}h -> {2} check(s) inside the pre-emptive window, worst-case user-visible exposure 0h." -f `
    $IntervalHours, $MinHoursRemaining, [math]::Floor($MinHoursRemaining / $IntervalHours))

# --- The check script (embedded fallback) ------------------------------------
# VERBATIM copy of scripts/host/check-tls-cert.ps1 from `param(` onward (its
# header comment block is the only thing dropped). If that file is found next to
# this one it is copied instead; this embed exists so the script still works
# when pasted alone onto a bare server. Keep the two in sync when editing.
$checkScript = @'
param(
    [string]$ComposeDir      = 'C:\ProgramData\3DX-Gateway',
    [string]$CaddyContainer  = '3dx-gateway-caddy',
    # Both default to the values install.ps1 wrote into <ComposeDir>\.env
    # (HOSTNAME / APP_PORT). Pass them only for a non-standard install.
    [string]$GatewayHostname = '',
    [int]$Port               = 0,
    # See invariant (a)/(b) in the header before changing this or the task's
    # repetition interval.
    [int]$MinHoursRemaining  = 3,
    # The delegate this watchdog used to blame without ever checking.
    [string]$AutostartTaskName = '3DX Gateway Autostart',
    # Debounce: never alarm on a single failed handshake.
    [int]$HandshakeAttempts     = 3,
    [int]$HandshakeRetrySeconds = 20,
    # Do not alarm while the host is still booting; the autostart task owns
    # that window (its boot trigger + start-3dx-stack.ps1's 6 min engine wait).
    [int]$BootGraceMinutes      = 12,
    [int]$MaxRecoveryAttempts   = 3,
    [int]$RecoveryCooldownHours = 6,
    # The delegate fault is logged on every pass but raised as an event log
    # entry at most this often, so an unfixed one does not bury the log in 24
    # identical events a day.
    [int]$DelegateAlarmEveryHours = 12,
    [string]$EventSource        = '3DX Gateway',
    # Report only -- never restart. Used by the installer for a first-run
    # sanity check, and handy for manual triage.
    [switch]$CheckOnly,
    # Alarm and classify, but never attempt any repair. For hosts where the
    # operator wants the diagnosis without the automation.
    [switch]$NoRecover
)

$ErrorActionPreference = 'Continue'
$LogFile   = Join-Path $ComposeDir 'autostart.log'
$StateFile = Join-Path $ComposeDir 'tls-watchdog-state.json'
$Marker    = Join-Path $ComposeDir 'GATEWAY-DOWN.txt'

function Log([string]$m) {
    $line = "{0}  [tls-watchdog] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

# --- Alarm channel: Windows Application event log ----------------------------
# Three writers, tried in order, because none of them is available everywhere:
#   1. [System.Diagnostics.EventLog]::WriteEntry -- works in Windows PowerShell
#      5.1 AND in pwsh 7 (the setup script prefers pwsh, and PowerShell 7 no
#      longer ships the *-EventLog cmdlets on every build).
#   2. the same call against the always-present 'Application' source, for the
#      case where setup never registered our own source.
#   3. eventcreate.exe. Its /ID is capped at 1000, so 900x is written as 90x --
#      logged explicitly when it happens rather than silently renumbering.
function Write-GatewayEvent {
    param(
        [int]$EventId,
        [ValidateSet('Error','Warning','Information')][string]$EntryType,
        [string]$Message
    )
    $body = "3DX Gateway watchdog (check-tls-cert.ps1)`r`nInstall: $ComposeDir`r`n`r`n$Message"
    try {
        [System.Diagnostics.EventLog]::WriteEntry(
            $EventSource, $body, [System.Diagnostics.EventLogEntryType]$EntryType, $EventId)
        return
    } catch { }
    try {
        [System.Diagnostics.EventLog]::WriteEntry(
            'Application', $body, [System.Diagnostics.EventLogEntryType]$EntryType, $EventId)
        Log "NOTE: event source '$EventSource' is not registered -- wrote the alarm under 'Application'."
        Log "      Register it by re-running setup-cert-watchdog.ps1 elevated."
        return
    } catch { }
    try {
        $small = $EventId
        if ($EventId -gt 1000) { $small = 900 + ($EventId - 9000) }
        $t = switch ($EntryType) { 'Error' { 'ERROR' } 'Warning' { 'WARNING' } default { 'INFORMATION' } }
        $d = ($body -replace '[\r\n]+', ' ')
        if ($d.Length -gt 1000) { $d = $d.Substring(0, 1000) }
        & eventcreate.exe /L APPLICATION /SO "3DX Gateway Watchdog" /T $t /ID $small /D $d 2>&1 | Out-Null
        Log "NOTE: alarm written via eventcreate.exe as event ID $small (it cannot write IDs above 1000; canonical ID is $EventId)."
    } catch {
        Log "ERROR: could not write to the Windows event log at all ($($_.Exception.Message)). The log file below is the only record."
    }
}

# --- Time helpers ------------------------------------------------------------
# Never let a timestamp round-trip through a culture-dependent string. Two traps
# collide here and both were hit while testing this script on an sr-Latn-RS host:
#   * ConvertFrom-Json returns a real [datetime] under PowerShell 7 but a plain
#     [string] under Windows PowerShell 5.1 -- and the task may run under either;
#   * coercing that [datetime] back to a string yields "08/10/2026", which
#     [datetime]::Parse then reads as 8 October under a dd.MM culture. That made
#     an outage 2 minutes old report as "-1414h" and would have silently broken
#     the repair cooldown arithmetic.
# So: parse with the invariant culture, treat a naive timestamp as UTC, and
# normalise everything back to one canonical string on the way in.
function ConvertTo-UtcTime($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) {
        if ($v.Kind -eq [System.DateTimeKind]::Local) { return $v.ToUniversalTime() }
        return [datetime]::SpecifyKind($v, [System.DateTimeKind]::Utc)
    }
    $s = [string]$v
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $r = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$r)) {
        return $r
    }
    return $null
}

function Format-UtcStamp($t) {
    if ($null -eq $t) { return '' }
    return $t.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-UtcNowStamp { return Format-UtcStamp ([datetime]::UtcNow) }

# Invariant so a Serbian/German-locale server does not log "-1.414,0h".
function Format-Hours([double]$h) {
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:N1}', $h)
}

# Hours elapsed since a stored stamp; $null when it cannot be determined.
function Get-HoursSince($stamp) {
    $t = ConvertTo-UtcTime $stamp
    if ($null -eq $t) { return $null }
    return ([datetime]::UtcNow - $t).TotalHours
}

# --- Outage state (rate limiting + escalation), persisted across runs ---------
function Get-State {
    $s = [pscustomobject]@{
        status           = 'ok'
        class            = ''
        firstDetectedUtc = ''
        checks           = 0
        recoveryAttempts = 0
        lastRecoveryUtc  = ''
        # Throttle for the delegate warning only. The delegate fault is real and
        # persistent, so it must not go away -- but at an hourly cadence it would
        # be 24 identical events a day forever. It is logged every pass and
        # raised as an event at most every -DelegateAlarmEveryHours.
        lastDelegateAlarmUtc = ''
    }
    if (-not (Test-Path $StateFile)) { return $s }
    try {
        $j = Get-Content -Path $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in @('status','class','firstDetectedUtc','checks','recoveryAttempts','lastRecoveryUtc','lastDelegateAlarmUtc')) {
            if ($null -ne $j.$p) { $s.$p = $j.$p }
        }
        $s.lastDelegateAlarmUtc = Format-UtcStamp (ConvertTo-UtcTime $s.lastDelegateAlarmUtc)
        # Normalise the two timestamps to the canonical invariant string
        # immediately, so nothing downstream ever sees a [datetime] (PS7) or a
        # locale-formatted string (PS5.1). See ConvertTo-UtcTime above.
        $s.firstDetectedUtc = Format-UtcStamp (ConvertTo-UtcTime $s.firstDetectedUtc)
        $s.lastRecoveryUtc  = Format-UtcStamp (ConvertTo-UtcTime $s.lastRecoveryUtc)
        $s.checks           = [int]$s.checks
        $s.recoveryAttempts = [int]$s.recoveryAttempts
    } catch {
        Log "WARN: $StateFile unreadable ($($_.Exception.Message)) -- starting from a clean state."
    }
    return $s
}

function Save-State($s) {
    try {
        $s | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding ASCII -ErrorAction Stop
    } catch {
        Log "WARN: could not write $StateFile ($($_.Exception.Message)) -- rate limiting will restart from zero next run."
    }
}

function Write-DownMarker($s, [string]$Title, [string[]]$Remedy) {
    $since = $s.firstDetectedUtc
    $h     = Get-HoursSince $since
    $dur   = if ($null -eq $h) { 'unknown' } else { (Format-Hours $h) + 'h' }
    $lines = @(
        '3DX GATEWAY IS DOWN'
        '==================='
        ''
        "Failure class    : $($s.class)"
        "What is wrong    : $Title"
        "First detected   : $since (UTC)"
        "Down for         : $dur, across $($s.checks) watchdog check(s)"
        "Repair attempts  : $($s.recoveryAttempts) of $MaxRecoveryAttempts"
        "Last checked     : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) (UTC)"
        ''
        'WHAT TO DO'
        '----------'
    )
    $lines += $Remedy
    $lines += @(
        ''
        'This file is written by the 3DX Gateway TLS/health watchdog and is deleted'
        'automatically on the first healthy check. Full history:'
        "  $LogFile   (lines tagged [tls-watchdog])"
        'Windows event log: Application, source "3DX Gateway", IDs 9000-9004.'
        ''
        'NOTE: port 80 on this server answers with Microsoft-IIS (the Windows default'
        'site). That is NOT the gateway. The gateway is on :443 and :8081.'
    )
    try {
        Set-Content -Path $Marker -Value $lines -Encoding ASCII -ErrorAction Stop
    } catch {
        Log "WARN: could not write $Marker ($($_.Exception.Message))."
    }
}

function Clear-DownState($s, [string]$What) {
    if ($s.status -eq 'down') {
        $h   = Get-HoursSince $s.firstDetectedUtc
        $dur = if ($null -eq $h) { 'unknown' } else { (Format-Hours $h) + 'h' }
        Log "RECOVERED: $What (was down for $dur across $($s.checks) check(s), class $($s.class))."
        Write-GatewayEvent -EventId 9000 -EntryType Information -Message @"
The 3DX Gateway is reachable again.

Recovered from : $($s.class)
Down for       : $dur across $($s.checks) watchdog check(s)
Repair attempts: $($s.recoveryAttempts)
Detail         : $What
"@
    }
    if (Test-Path $Marker) { Remove-Item -Path $Marker -Force -ErrorAction SilentlyContinue }
    $s.status = 'ok'; $s.class = ''; $s.firstDetectedUtc = ''
    $s.checks = 0; $s.recoveryAttempts = 0; $s.lastRecoveryUtc = ''
    Save-State $s
}

# --- Read the install's own settings out of .env -----------------------------
# install.ps1 writes HOSTNAME / APP_PORT / TLS_MODE there. Explicit parameters
# win; .env fills the rest; only then do we fall back to a guess.
$tlsMode = 'auto'
$envPath = Join-Path $ComposeDir '.env'
if (Test-Path $envPath) {
    foreach ($line in (Get-Content $envPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*HOSTNAME\s*=\s*(.+?)\s*$'  -and -not $GatewayHostname) { $GatewayHostname = $Matches[1] }
        if ($line -match '^\s*APP_PORT\s*=\s*(\d+)\s*$'  -and $Port -le 0)            { $Port = [int]$Matches[1] }
        if ($line -match '^\s*TLS_MODE\s*=\s*(\S+)\s*$')                              { $tlsMode = $Matches[1] }
    }
} else {
    Log "WARN: $envPath not found; relying on parameters/defaults."
}
if (-not $GatewayHostname) { $GatewayHostname = [System.Net.Dns]::GetHostEntry('localhost').HostName }
if ($Port -le 0)           { $Port = 443 }

if ($tlsMode -eq 'none') {
    Log "TLS_MODE=none (no Caddy certificate to watch). Nothing to do."
    exit 0
}

Log "=== check begin (host=$GatewayHostname port=$Port container=$CaddyContainer minHours=$MinHoursRemaining) ==="

$state = Get-State

# --- 0. Delegate check -------------------------------------------------------
# Runs on EVERY pass, healthy or not, and is strictly read-only. The 2026-08-08
# outage lasted 36h because this watchdog delegated recovery to a Scheduled Task
# that had been failing since the day before -- and never looked. A component
# that points at another component must verify that the other one still exists.
function Get-AutostartTaskProblems([string]$Name) {
    $problems = @()
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return @()   # no ScheduledTasks module: nothing to say, do not invent a fault
    }
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop } catch { }
    if (-not $task) {
        return @("scheduled task '$Name' does NOT EXIST -- nothing brings the stack up after a reboot. Fix: run scripts/host/setup-autostart.ps1 elevated.")
    }
    if ($task.State -eq 'Disabled') {
        $problems += "task '$Name' is DISABLED. Fix: Enable-ScheduledTask -TaskName '$Name'"
    }

    $hasLogon = $false
    $hasRepeat = $false
    foreach ($t in @($task.Triggers)) {
        $cls = ''
        try { $cls = [string]$t.CimClass.CimClassName } catch { }
        if ($cls -eq 'MSFT_TaskLogonTrigger') { $hasLogon = $true }
        try {
            if ($t.Repetition -and $t.Repetition.Interval) { $hasRepeat = $true }
        } catch { }
    }
    if (-not $hasLogon) {
        $problems += "task '$Name' has NO at-logon trigger. On a Docker Desktop host that is the only trigger that can actually start the engine (session 0 cannot). Fix: re-run setup-autostart.ps1 elevated."
    }
    if (-not $hasRepeat) {
        $problems += "task '$Name' has NO repetition interval -- a boot attempt that fails is never retried. Fix: re-run setup-autostart.ps1 elevated."
    }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
        # 0 = ok, 0x41301 (267009) = currently running, 0x41303 (267011) = has not run yet
        if ($null -ne $info.LastTaskResult -and
            $info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 267009 -and $info.LastTaskResult -ne 267011) {
            $problems += ("task '$Name' last run FAILED: LastTaskResult={0} (last run {1})." -f $info.LastTaskResult, $info.LastRunTime)
        }
        if (-not $info.NextRunTime) {
            $problems += "task '$Name' has NO next run time -- it will not fire again until the next reboot."
        }
    } catch { }

    return $problems
}

$delegateProblems = @(Get-AutostartTaskProblems $AutostartTaskName)
if ($delegateProblems.Count -gt 0) {
    Log "DELEGATE PROBLEM: the autostart task this watchdog relies on is not healthy:"
    foreach ($p in $delegateProblems) { Log "   - $p" }
    $sinceDelegateAlarm = Get-HoursSince $state.lastDelegateAlarmUtc
    if ($null -ne $sinceDelegateAlarm -and $sinceDelegateAlarm -lt $DelegateAlarmEveryHours) {
        Log ("(event log entry throttled: last 9004 raised {0}h ago, one per {1}h)" -f (Format-Hours $sinceDelegateAlarm), $DelegateAlarmEveryHours)
    } else {
        $state.lastDelegateAlarmUtc = Get-UtcNowStamp
        Save-State $state
        Write-GatewayEvent -EventId 9004 -EntryType Warning -Message @"
The '$AutostartTaskName' Scheduled Task is not healthy. The gateway may not come
back on its own after the next reboot or engine restart.

$($delegateProblems -join "`r`n")

The TLS watchdog only reports this; it never modifies the task.
"@
    }
} else {
    Log "delegate ok: '$AutostartTaskName' exists, is enabled, has a logon trigger + repetition, and last exited 0."
}

# --- 1. What is actually served on the wire ----------------------------------
# Connect over loopback but send the real hostname as SNI, so Caddy hands back
# the same leaf a LAN browser gets. Certificate validation is deliberately
# accepted: we want to INSPECT an invalid cert, not reject it.
function Get-ServedCertificate {
    param([string]$SniHost, [int]$TcpPort)
    $tcp = $null
    $ssl = $null
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $tcp.Connect('127.0.0.1', $TcpPort)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($SniHost)
        return New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
}

# Debounced: a single refused connection is not an outage (Caddy reloading, the
# restart this very script performs, a boot still in progress).
function Get-ServedCertificateRetrying {
    param([int]$Attempts, [int]$DelaySeconds)
    $lastErr = ''
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            return @{ Cert = (Get-ServedCertificate -SniHost $GatewayHostname -TcpPort $Port); Error = '' }
        } catch {
            $lastErr = $_.Exception.Message
            if ($i -lt $Attempts) {
                Log ("handshake attempt {0}/{1} failed ({2}); retrying in {3}s" -f $i, $Attempts, $lastErr, $DelaySeconds)
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
    return @{ Cert = $null; Error = $lastErr }
}

# --- Docker probes (the ladder that classifies the failure) ------------------
function Get-DockerEngineVersion {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $null }
    $v = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($v)) { return ($v | Select-Object -First 1).Trim() }
    return $null
}

function Get-ContainerStatus([string]$Name) {
    # 'missing' when the container does not exist at all; otherwise Docker's own
    # State.Status (running / exited / restarting / created / paused / dead).
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'unknown' }
    $s = & docker inspect -f '{{.State.Status}}' $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($s)) { return 'missing' }
    return ($s | Select-Object -First 1).Trim()
}

function Get-HostUptimeMinutes {
    try {
        $b = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        return ((Get-Date) - $b).TotalMinutes
    } catch { return 99999 }
}

# --- Rate-limited, narrow recovery -------------------------------------------
function Test-RecoveryAllowed($s) {
    if ($CheckOnly)  { Log "-CheckOnly: not attempting any repair."; return $false }
    if ($NoRecover)  { Log "-NoRecover: not attempting any repair."; return $false }
    if ($s.recoveryAttempts -ge $MaxRecoveryAttempts) {
        Log "repair cap reached ($($s.recoveryAttempts)/$MaxRecoveryAttempts attempts this outage) -- escalating only, no further attempts."
        return $false
    }
    $since = Get-HoursSince $s.lastRecoveryUtc
    if ($null -ne $since -and $since -lt $RecoveryCooldownHours) {
        Log ("repair cooldown: last attempt {0}h ago, minimum spacing {1}h -- not retrying yet." -f (Format-Hours $since), $RecoveryCooldownHours)
        return $false
    }
    return $true
}

function Invoke-StackStart($s) {
    # No new recovery logic: this calls the SAME script the boot task runs. It
    # is the only thing that resolves the install's real compose overlay set.
    $starter = Join-Path (Join-Path $ComposeDir 'host') 'start-3dx-stack.ps1'
    if (-not (Test-Path $starter)) {
        Log "cannot repair: $starter is missing (re-run setup-autostart.ps1 to install it). No ad-hoc 'compose up' attempted -- a bare one would strip the helper/TLS overlays."
        return $false
    }
    $s.recoveryAttempts = [int]$s.recoveryAttempts + 1
    $s.lastRecoveryUtc  = Get-UtcNowStamp
    Save-State $s
    Log "REPAIR ATTEMPT $($s.recoveryAttempts)/${MaxRecoveryAttempts}: & `"$starter`" -ComposeDir `"$ComposeDir`""
    Push-Location
    try {
        $out = & $starter -ComposeDir $ComposeDir 2>&1
        foreach ($l in $out) { Log "  | $l" }
    } catch {
        Log "  | REPAIR ATTEMPT threw: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
    return $true
}

function Invoke-CaddyRestart($s) {
    $s.recoveryAttempts = [int]$s.recoveryAttempts + 1
    $s.lastRecoveryUtc  = Get-UtcNowStamp
    Save-State $s
    Log "REPAIR ATTEMPT $($s.recoveryAttempts)/${MaxRecoveryAttempts}: docker restart $CaddyContainer"
    $out = & docker restart $CaddyContainer 2>&1
    foreach ($l in $out) { Log "  | $l" }
    if ($LASTEXITCODE -ne 0) {
        Log "  | 'docker restart $CaddyContainer' exited $LASTEXITCODE."
        return $false
    }
    return $true
}

# Re-handshake after a repair, with a longer budget than the debounce loop.
function Wait-ForListener([int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try { return (Get-ServedCertificate -SniHost $GatewayHostname -TcpPort $Port) } catch { }
    }
    return $null
}

# --- 2. Handshake, and classify when it fails --------------------------------
$hs   = Get-ServedCertificateRetrying -Attempts $HandshakeAttempts -DelaySeconds $HandshakeRetrySeconds
$cert = $hs.Cert

if (-not $cert) {
    Log "ERROR: no TLS handshake on 127.0.0.1:$Port after $HandshakeAttempts attempts ($($hs.Error))."

    # Boot grace: the autostart task owns the first minutes after a reboot
    # (start-3dx-stack.ps1 waits up to 6 min for the engine alone). Alarming
    # there would train the operator to ignore this alarm.
    $upMin = Get-HostUptimeMinutes
    if ($upMin -lt $BootGraceMinutes) {
        Log ("host booted {0:N1} min ago (grace {1} min) -- the autostart task still owns this window. No alarm, no repair." -f $upMin, $BootGraceMinutes)
        Log "=== check end ==="
        exit 1
    }

    # Probe ladder. This is the part the old script never reached: it quit here
    # WITHOUT knowing whether the engine or only the container was gone, and
    # then printed a message that blamed the container.
    $engineVer = Get-DockerEngineVersion
    $class = ''; $title = ''; $remedy = @(); $recoverable = $false

    if (-not $engineVer) {
        $class = 'ENGINE_DOWN'
        $title = 'The Docker engine is not reachable. The containers are not merely stopped -- there is no engine under them.'
        $recoverable = $false
        Log "CLASS A -- ENGINE DOWN: 'docker version' does not return a server."
        Log "         This is NOT the 'Caddy container fell over' case. 'restart: unless-stopped' cannot help:"
        Log "         it restarts containers, not the engine that hosts them. This is what happened on"
        Log "         2026-08-08, when Docker Desktop updated itself and killed its own service."
        Log "         No repair attempted: on a Docker-Desktop-only host the WSL2 backend cannot be"
        Log "         initialised from session 0 (which is where this task runs), so an attempt would fail."
        $remedy = @(
            'The Docker ENGINE is gone, not just a container. Nothing on this host can'
            'fix that unattended while Docker Desktop is the only engine.'
            ''
            'Immediate recovery: sign in to the server as the account that owns Docker'
            'Desktop, wait for the whale icon to go steady, then run (elevated):'
            "    pwsh -File `"$ComposeDir\host\start-3dx-stack.ps1`" -ComposeDir `"$ComposeDir`""
            ''
            'Permanent fix, in order of preference:'
            '  1. Move the gateway to a Linux runtime (Docker Engine + systemd): a Hyper-V'
            '     VM on this host, or a separate Linux host. See ADR-029. Then boot needs'
            '     no sign-in at all. NOTE: a native Windows docker service (Docker CE /'
            '     Mirantis) is NOT a fix -- it runs Windows containers only, and every'
            '     image in this stack is linux/amd64.'
            '  2. Enable automatic sign-in for the Docker Desktop service account, so the'
            "     at-logon trigger on '$AutostartTaskName' brings the stack up after boot."
            '  3. Sign in after every reboot.'
            ''
            'Also check whether Docker Desktop auto-updated: System event log, IDs 7034 /'
            '7045 for "Docker Desktop Service". That is what caused the 2026-08-08 outage.'
        )
    } else {
        $status = Get-ContainerStatus $CaddyContainer
        Log "engine is alive (Server $engineVer); container '$CaddyContainer' status = $status"
        if ($status -eq 'running') {
            $class = 'CADDY_NOT_SERVING'
            $title = "The '$CaddyContainer' container is running but nothing answers TLS on :$Port."
            $recoverable = $true
            Log "CLASS C -- CONTAINER UP BUT NOT SERVING: engine and container are alive, the listener is not."
        } else {
            $class = 'CADDY_DOWN'
            $title = "The '$CaddyContainer' container is '$status' while the Docker engine is healthy."
            $recoverable = $true
            Log "CLASS B -- CONTAINER DOWN: engine alive, container '$status'."
        }
        $remedy = @(
            'The Docker engine is alive; the gateway container is not serving. Run'
            'this elevated on the server:'
            "    pwsh -File `"$ComposeDir\host\start-3dx-stack.ps1`" -ComposeDir `"$ComposeDir`""
            ''
            'Do NOT run a bare "docker compose up -d" in the install directory: it'
            'reconciles against docker-compose.yml only and silently drops the TLS and'
            'helper overlays. The script above resolves the real overlay set.'
            ''
            "Diagnosis: docker ps -a  /  docker logs $CaddyContainer"
        )
    }

    # Escalating outage bookkeeping.
    if ($state.status -ne 'down' -or $state.class -ne $class) {
        if ($state.status -eq 'down' -and $state.class -ne $class) {
            Log "failure class changed: $($state.class) -> $class (repair counter reset)."
        }
        $state.status           = 'down'
        $state.class            = $class
        $state.firstDetectedUtc = Get-UtcNowStamp
        $state.checks           = 1
        $state.recoveryAttempts = 0
        $state.lastRecoveryUtc  = ''
    } else {
        $state.checks = [int]$state.checks + 1
    }
    $downHours = Get-HoursSince $state.firstDetectedUtc
    if ($null -eq $downHours) { $downHours = 0.0 }
    Log ("DOWN for {0} check(s) / {1}h (class {2})." -f $state.checks, (Format-Hours $downHours), $class)
    Save-State $state
    Write-DownMarker $state $title $remedy

    Write-GatewayEvent -EventId $(if ($class -eq 'ENGINE_DOWN') { 9001 } else { 9002 }) -EntryType Error -Message @"
THE 3DX GATEWAY IS DOWN. https://$GatewayHostname`:$Port does not answer.

Failure class : $class
What is wrong : $title
Down for      : $(Format-Hours $downHours)h, across $($state.checks) watchdog check(s)
First detected: $($state.firstDetectedUtc)

$($remedy -join "`r`n")

Details: $Marker
Log    : $LogFile   (lines tagged [tls-watchdog])
"@

    # Narrow, rate-limited repair -- classes B and C only.
    if ($recoverable -and (Test-RecoveryAllowed $state)) {
        $ran = $false
        if ($class -eq 'CADDY_NOT_SERVING') { $ran = Invoke-CaddyRestart $state }
        else                                { $ran = Invoke-StackStart   $state }
        if ($ran) {
            $back = Wait-ForListener -TimeoutSeconds 120
            if ($back) {
                Log ("REPAIR SUCCEEDED: :{0} answers again (leaf NotAfter={1}Z)." -f `
                     $Port, $back.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))
                Clear-DownState $state "repaired automatically after the $class failure"
                Log "=== check end ==="
                exit 0
            }
            Log "REPAIR FAILED: :$Port still does not answer 120s after the attempt. Alarm stands."
        }
    } elseif (-not $recoverable) {
        Log "no repair attempted for class $class by design -- see the remedy in $Marker."
    }

    Log "=== check end ==="
    exit 1
}

# --- 3. The handshake works: inspect the certificate -------------------------
$now       = (Get-Date).ToUniversalTime()
$notAfter  = $cert.NotAfter.ToUniversalTime()
$remaining = $notAfter - $now
Log ("served leaf: NotAfter={0}Z remaining={1:N1}h issuer='{2}'" -f `
     $notAfter.ToString('yyyy-MM-dd HH:mm:ss'), $remaining.TotalHours, $cert.Issuer)

$expiryBad = ($remaining.TotalHours -lt $MinHoursRemaining)
if ($expiryBad) {
    if ($remaining.TotalHours -lt 0) {
        Log ("PROBLEM: certificate EXPIRED {0:N1}h ago -- browsers are showing 'Not secure'." -f (-$remaining.TotalHours))
    } else {
        Log ("PROBLEM: certificate expires in {0:N1}h (threshold {1}h) and has not been renewed." -f $remaining.TotalHours, $MinHoursRemaining)
    }
}

# --- 4. Is the key that backs it still in the volume? ------------------------
# The leading indicator. Issuer-agnostic glob: 'local' for `tls internal`,
# an acme-v02 directory for Let's Encrypt.
$storeBad = $false
$dockerOk = $true
$engineVersion = Get-DockerEngineVersion
if (-not $engineVersion) {
    # Same failure mode the Apply Update worker guards against: docker.exe
    # resolves but the engine is unreachable for THIS account (SYSTEM, named
    # pipe ACL, engine not started). Note that TLS still answers here, so the
    # site is up -- this is a degraded check, not an outage.
    $dockerOk = $false
    Log "WARN: cannot reach the Docker engine as $($env:USERNAME) -- skipping the key-file check."
} else {
    $keyGlob = "/data/caddy/certificates/*/$GatewayHostname/$GatewayHostname.key"
    $found = & docker exec $CaddyContainer sh -c "ls $keyGlob 2>/dev/null | head -n 1" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Log "WARN: 'docker exec $CaddyContainer' failed -- skipping the key-file check."
    } elseif ([string]::IsNullOrWhiteSpace($found)) {
        $storeBad = $true
        Log "PROBLEM: private key missing from the volume ($keyGlob)."
        Log "         Caddy is serving a cached certificate it can no longer renew -- this is the"
        Log "         2026-07 delmiaworks04 failure, caught before the cached cert expires."
    } else {
        Log "stored key present: $($found.Trim())"
    }
}

if (-not ($expiryBad -or $storeBad)) {
    Log "OK: certificate healthy and backed by the volume. No action."
    Clear-DownState $state 'certificate healthy and the site answers'
    Log "=== check end ==="
    exit 0
}

# From here on the site answers but the certificate is broken or unrenewable.
$certClass  = 'CERT_UNRENEWABLE'
$certTitle  = if ($expiryBad -and $remaining.TotalHours -lt 0) {
    'The served certificate has EXPIRED. Every browser shows "Not secure".'
} elseif ($expiryBad) {
    'The served certificate is about to expire and Caddy is not renewing it.'
} else {
    'Caddy is serving a cached certificate whose private key is gone from the volume; it can never renew it.'
}
$certRemedy = @(
    'The site answers, but its certificate is broken. The repair is:'
    "    docker restart $CaddyContainer"
    'On startup Caddy rebuilds its certificate store and issues a fresh leaf.'
    ''
    'If a restart does not fix it, read the Caddy log for the real cause'
    '(disk full, read-only volume, bad Caddyfile):'
    "    docker logs --tail 200 $CaddyContainer"
)

if ($state.status -ne 'down' -or $state.class -ne $certClass) {
    $state.status           = 'down'
    $state.class            = $certClass
    $state.firstDetectedUtc = Get-UtcNowStamp
    $state.checks           = 1
    $state.recoveryAttempts = 0
    $state.lastRecoveryUtc  = ''
} else {
    $state.checks = [int]$state.checks + 1
}
Save-State $state

if ($CheckOnly) {
    Log "-CheckOnly: a restart of '$CaddyContainer' is what would fix this. Not restarting."
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Warning -Message @"
The 3DX Gateway TLS certificate needs attention (reported by a -CheckOnly pass,
no repair attempted).

$certTitle

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

# --- 5. Repair: restart Caddy ------------------------------------------------
# On startup Caddy re-reads its storage and runs certificate maintenance
# immediately, which reissues anything expired/missing. Cost is a few seconds
# of refused connections on :443 -- far cheaper than the alternative. This is
# the repair that was fault-injection tested on dev01 on 2026-07-27.
if (-not $dockerOk) {
    Log "ERROR: repair needed but the Docker engine is unreachable from this account. Run manually:"
    Log "       docker restart $CaddyContainer"
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Error -Message @"
The 3DX Gateway TLS certificate is broken and the watchdog CANNOT repair it: the
Docker engine is unreachable from the account the watchdog runs as.

$certTitle

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

if (-not (Test-RecoveryAllowed $state)) {
    Log "ERROR: certificate is broken but the repair budget for this outage is spent. Escalating only."
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Error -Message @"
The 3DX Gateway TLS certificate is broken and automatic repair has been given up
after $($state.recoveryAttempts) attempt(s). MANUAL ACTION IS REQUIRED.

$certTitle
Down for: $($state.checks) watchdog check(s) since $($state.firstDetectedUtc)

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

if (-not (Invoke-CaddyRestart $state)) {
    Log "ERROR: the restart command failed. Manual intervention required."
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Error -Message @"
The 3DX Gateway TLS certificate is broken and 'docker restart $CaddyContainer'
FAILED.

$certTitle

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

# Wait for the listener to come back, then re-inspect. Verifying the FIX is the
# point: a restart that silently produced another bad cert must still be loud.
$newCert = Wait-ForListener -TimeoutSeconds 120
if (-not $newCert) {
    Log "ERROR: :$Port did not answer within 120s after the restart. Check 'docker logs $CaddyContainer'."
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Error -Message @"
The 3DX Gateway did not come back after the watchdog restarted
'$CaddyContainer'. THE SITE IS NOW DOWN.

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

$newRemaining = $newCert.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()
Log ("new leaf: NotAfter={0}Z remaining={1:N1}h" -f `
     $newCert.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $newRemaining.TotalHours)

if ($newRemaining.TotalHours -lt $MinHoursRemaining) {
    Log "ERROR: still below the threshold after a restart. Caddy cannot issue a certificate --"
    Log "       inspect 'docker logs $CaddyContainer' (disk full, read-only volume, bad Caddyfile)."
    Write-DownMarker $state $certTitle $certRemedy
    Write-GatewayEvent -EventId 9003 -EntryType Error -Message @"
The 3DX Gateway TLS certificate is STILL broken after a restart of
'$CaddyContainer'. Caddy cannot issue a certificate at all. MANUAL ACTION IS
REQUIRED.

New leaf has $(Format-Hours $newRemaining.TotalHours)h left, threshold is ${MinHoursRemaining}h.

$($certRemedy -join "`r`n")
"@
    Log "=== check end ==="
    exit 1
}

Log "FIXED: fresh certificate issued and served."
Clear-DownState $state 'a fresh certificate was issued and is being served'
Log "=== check end ==="
exit 0
'@

# --- 1. Register the Windows event log source --------------------------------
# The watchdog runs as SYSTEM and could create the source itself, but creating
# one scans the whole EventLog registry tree on first use; doing it here, once,
# in an already-elevated process, keeps every later run cheap. Three ways,
# because PowerShell 7 does not ship New-EventLog on every build.
function Register-GatewayEventSource([string]$Source) {
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($Source)) {
            Write-Host "Event log source '$Source' already registered."
            return $true
        }
    } catch { }
    try {
        [System.Diagnostics.EventLog]::CreateEventSource($Source, 'Application')
        Write-Host "Registered event log source '$Source' in the Application log."
        return $true
    } catch { }
    try {
        New-EventLog -LogName 'Application' -Source $Source -ErrorAction Stop
        Write-Host "Registered event log source '$Source' (New-EventLog)."
        return $true
    } catch { }
    try {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$Source"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Write-Host "Registered event log source '$Source' via the registry."
        return $true
    } catch {
        Write-Warning "Could not register event log source '$Source': $($_.Exception.Message)"
        Write-Warning "Alarms will fall back to the 'Application' source; nothing else is lost."
        return $false
    }
}
Register-GatewayEventSource $EventSource | Out-Null

# --- 2. Write the check script -----------------------------------------------
$hostDir = Join-Path $InstallDir 'host'
New-Item -ItemType Directory -Force -Path $hostDir | Out-Null
$checkPath = Join-Path $hostDir 'check-tls-cert.ps1'

$sibling = Join-Path $PSScriptRoot 'check-tls-cert.ps1'
if ((Test-Path $sibling) -and ((Resolve-Path $sibling).Path -ne $checkPath)) {
    Copy-Item -Path $sibling -Destination $checkPath -Force
    Write-Host "Copied check script from $sibling"
} else {
    Set-Content -Path $checkPath -Value $checkScript -Encoding ASCII
    Write-Host "Wrote embedded check script to $checkPath"
}

# The classified-failure remedies point the operator at start-3dx-stack.ps1, and
# the class-B repair actually invokes it. Say so plainly at install time rather
# than letting the first outage discover it is missing.
$starter = Join-Path $hostDir 'start-3dx-stack.ps1'
if (-not (Test-Path $starter)) {
    Write-Warning "$starter is missing."
    Write-Warning "The watchdog will still detect and ALARM on a dead stack, but it cannot attempt the"
    Write-Warning "'engine alive, container down' repair (it refuses to run a bare 'compose up -d', which"
    Write-Warning "would strip the TLS/helper overlays). Install it with: setup-autostart.ps1"
}

# --- 3. Register the Scheduled Task ------------------------------------------
$psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command powershell).Source }

$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$checkPath`"" +
           " -ComposeDir `"$InstallDir`" -CaddyContainer `"$CaddyContainer`"" +
           " -MinHoursRemaining $MinHoursRemaining" +
           " -AutostartTaskName `"$AutostartTaskName`"" +
           " -EventSource `"$EventSource`"" +
           " -MaxRecoveryAttempts $MaxRecoveryAttempts" +
           " -RecoveryCooldownHours $RecoveryCooldownHours" +
           " -DelegateAlarmEveryHours $DelegateAlarmEveryHours"
if ($NoRecover) { $argLine += ' -NoRecover' }
$action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine

# Two triggers: one after boot (the reboot that killed the volume is exactly
# when the damage happens, so check early), and a repeating one.
#
# The boot delay is PT10M, not PT5M: the autostart task's own boot trigger fires
# at PT1M and start-3dx-stack.ps1 then waits up to 6 minutes for the engine. At
# PT5M this task could fire mid-boot and -- now that it ALARMS -- raise a false
# "gateway is down" event. The check script additionally refuses to alarm while
# host uptime is under 12 minutes; the two guards are deliberately redundant.
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT10M'

# -RepetitionDuration ([TimeSpan]::MaxValue) is the documented "forever" idiom
# but throws on some Windows builds; 10 years is indefinite in practice and
# registers everywhere.
$repeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

# ExecutionTimeLimit 20 min, not 10: a class-B repair invokes start-3dx-stack.ps1,
# which alone may wait 6 minutes for the engine, and the post-repair handshake
# wait adds another 2. IgnoreNew keeps the hourly repetition from stacking runs
# on top of one that is still inside a repair.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -MultipleInstances IgnoreNew

# SYSTEM: no password to store, and no user profile needed (the engine is
# already running by the time this fires).
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

# Idempotent: drop an existing task with the same name first. This is also the
# fix for the drift found on 2026-08-10 -- shipping a newer script does NOT
# re-register the task, so an install can run for months on triggers written by
# an older version. Re-running this script is the only thing that updates them.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Write-Host "Registering '$TaskName' (SYSTEM, every $IntervalHours h + 10 min after startup)..."
Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($bootTrigger, $repeatTrigger) -Settings $settings `
    -Principal $principal | Out-Null

# --- 4. Report the delegate's health right now -------------------------------
# The check script does this on every pass, but the operator standing here
# deserves to know immediately -- this is exactly the drift that turned a
# Docker Desktop self-update into a 36-hour outage.
try {
    $at = Get-ScheduledTask -TaskName $AutostartTaskName -ErrorAction Stop
    $ati = Get-ScheduledTaskInfo -TaskName $AutostartTaskName -ErrorAction SilentlyContinue
    $trigNames = @()
    foreach ($t in @($at.Triggers)) {
        try { $trigNames += [string]$t.CimClass.CimClassName } catch { }
    }
    Write-Host ''
    Write-Host "Delegate task '$AutostartTaskName':"
    Write-Host "  State          : $($at.State)"
    Write-Host "  Triggers       : $($trigNames -join ', ')"
    if ($ati) {
        Write-Host "  LastRunTime    : $($ati.LastRunTime)"
        Write-Host "  LastTaskResult : $($ati.LastTaskResult)"
        Write-Host "  NextRunTime    : $($ati.NextRunTime)"
    }
    if ($trigNames -notcontains 'MSFT_TaskLogonTrigger' -or
        ($ati -and $ati.LastTaskResult -ne 0 -and $ati.LastTaskResult -ne 267009 -and $ati.LastTaskResult -ne 267011) -or
        ($ati -and -not $ati.NextRunTime)) {
        Write-Warning "The autostart task is NOT healthy (no logon trigger / failing / no next run time)."
        Write-Warning "Re-run setup-autostart.ps1 elevated. Until then, nothing brings the stack back after a reboot."
    }
} catch {
    Write-Warning "Delegate task '$AutostartTaskName' not found -- nothing brings the stack up after a reboot."
    Write-Warning "Run scripts/host/setup-autostart.ps1 elevated."
}

# --- 5. One inline read-only pass so the operator sees the current state ------
# -CheckOnly never restarts, so this is safe to run mid-install. It exits 1 when
# something is already wrong -- report it, but don't fail the setup over it.
Write-Host ''
Write-Host 'Current gateway state:'
& $checkPath -ComposeDir $InstallDir -CaddyContainer $CaddyContainer `
    -MinHoursRemaining $MinHoursRemaining -AutostartTaskName $AutostartTaskName `
    -EventSource $EventSource -CheckOnly
$checkExit = $LASTEXITCODE

Write-Host ''
if ($checkExit -eq 0) {
    Write-Host "Done. The gateway is healthy and will be checked every $IntervalHours h." -ForegroundColor Green
} else {
    Write-Host "Done -- but the check above reported a problem." -ForegroundColor Yellow
    Write-Host "If it is the certificate:  docker restart $CaddyContainer"
    Write-Host "If the stack is down:      pwsh -File `"$starter`" -ComposeDir `"$InstallDir`""
    Write-Host "(or let the task try at its next run)"
}
Write-Host ''
Write-Host "Run it on demand:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Log:                $(Join-Path $InstallDir 'autostart.log')  (lines tagged [tls-watchdog])"
Write-Host "When down:          $(Join-Path $InstallDir 'GATEWAY-DOWN.txt')  (written on failure, deleted on recovery)"
Write-Host "State/rate limit:   $(Join-Path $InstallDir 'tls-watchdog-state.json')"
Write-Host "Alarms:             Event Viewer -> Windows Logs -> Application, source '$EventSource'"
Write-Host "                      9001 Docker engine gone      9002 Caddy container down / not serving"
Write-Host "                      9003 certificate unrenewable 9004 autostart task unhealthy"
Write-Host "                      9000 recovered"
Write-Host "  Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='$EventSource'} -MaxEvents 20"
Write-Host "Repair policy:      at most $MaxRecoveryAttempts attempt(s) per outage, at most one per $RecoveryCooldownHours h;"
Write-Host "                    NEVER attempted when the Docker engine itself is gone (it cannot be"
Write-Host "                    started from session 0 on a Docker Desktop host -- that needs a sign-in)."
Write-Host "Remove later with:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
