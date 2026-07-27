<#
.SYNOPSIS
3DX Gateway -- one-shot setup for the TLS certificate watchdog.

.DESCRIPTION
Self-contained. Run this ONCE on the gateway server (elevated) to register a
Scheduled Task that keeps the Caddy TLS certificate healthy.

Why this is needed: Caddy's `tls internal` leaf certificates live 12 hours and
are auto-renewed -- but only while Caddy can read and write its storage volume.
On Windows that volume lives inside Docker Desktop's WSL2 VHDX, which Windows
tears down without a graceful container stop on power loss AND on ordinary
Windows Update reboots. When that loses the leaf's private key, Caddy keeps
serving the certificate it already holds in memory (site stays up, app answers
200) while every renewal fails -- and roughly 8 hours later the cached
certificate expires and every browser shows "Not secure". On delmiaworks04
that state went unnoticed for 23 days because the only signal was a log line.

The watchdog checks the certificate actually served on :443 plus the key file
backing it, and restarts the Caddy container when either is broken. Restarting
makes Caddy rebuild its store and issue a fresh leaf.

What it does:
  1. Writes the check script to <InstallDir>\host\check-tls-cert.ps1 (copies
     the sibling check-tls-cert.ps1 if present, else writes an embedded copy).
  2. Registers the "3DX Gateway TLS Watchdog" Scheduled Task (runs as SYSTEM;
     at startup + every -IntervalHours; highest privileges).
  3. Runs one -CheckOnly pass inline so you see the current state immediately.

Runs as SYSTEM deliberately: unlike the boot autostart task it never has to
start Docker Desktop (it only talks to an already-running engine), so it needs
no user profile and no stored password -- which also makes it safe to install
unattended.

ASCII-only on purpose (PS 5.1 misparses non-ASCII depending on host codepage).

.PARAMETER InstallDir
Compose install dir. Default: C:\ProgramData\3DX-Gateway

.PARAMETER IntervalHours
How often to check. Default 4. Bounds the worst case: a certificate that dies
between two checks is user-visible for at most this long (versus 23 days
unattended). Cheap enough to run often -- one TLS handshake plus one `docker
exec ls`.

.PARAMETER MinHoursRemaining
Restart when the served leaf has less than this many hours left. Default 2.
Healthy `tls internal` operation never drops below ~4h (Caddy renews at two
thirds of a 12h lifetime), so 2h means "renewal is definitely not happening"
rather than "renewal is due".

.EXAMPLE
PS> .\setup-cert-watchdog.ps1
# Registers the task, then verify:
PS> Start-ScheduledTask -TaskName '3DX Gateway TLS Watchdog'
PS> Get-Content C:\ProgramData\3DX-Gateway\autostart.log -Tail 30
#>

[CmdletBinding()]
param(
    [string]$InstallDir         = 'C:\ProgramData\3DX-Gateway',
    [string]$TaskName           = '3DX Gateway TLS Watchdog',
    [string]$CaddyContainer     = '3dx-gateway-caddy',
    [int]$IntervalHours         = 4,
    [int]$MinHoursRemaining     = 2
)

$ErrorActionPreference = 'Stop'

# --- Admin guard -------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this elevated (Run as Administrator)."
}

# --- The check script (embedded fallback) ------------------------------------
# Logic mirrors scripts/host/check-tls-cert.ps1 (minus its header block). If
# that file is found next to this one it is copied verbatim; otherwise this
# embedded copy is written (so the script is fully self-contained when pasted
# onto a bare server). Keep the two in sync when editing the check logic.
$checkScript = @'
param(
    [string]$ComposeDir      = 'C:\ProgramData\3DX-Gateway',
    [string]$CaddyContainer  = '3dx-gateway-caddy',
    [string]$GatewayHostname = '',
    [int]$Port               = 0,
    [int]$MinHoursRemaining  = 2,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'
$LogFile = Join-Path $ComposeDir 'autostart.log'

function Log([string]$m) {
    $line = "{0}  [tls-watchdog] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

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

$cert = $null
try {
    $cert = Get-ServedCertificate -SniHost $GatewayHostname -TcpPort $Port
} catch {
    Log "ERROR: cannot complete a TLS handshake on 127.0.0.1:$Port ($($_.Exception.Message))."
    Log "       Caddy is not listening. That is the autostart task's job, not this one. No restart attempted."
    exit 1
}

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

$storeBad = $false
$dockerOk = $true
$verLine = & docker version --format '{{.Server.Version}}' 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verLine)) {
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
        Log "         Caddy is serving a cached certificate it can no longer renew."
    } else {
        Log "stored key present: $($found.Trim())"
    }
}

if (-not ($expiryBad -or $storeBad)) {
    Log "OK: certificate healthy and backed by the volume. No action."
    Log "=== check end ==="
    exit 0
}

if ($CheckOnly) {
    Log "-CheckOnly: a restart of '$CaddyContainer' is what would fix this. Not restarting."
    Log "=== check end ==="
    exit 1
}

if (-not $dockerOk) {
    Log "ERROR: repair needed but the Docker engine is unreachable from this account. Run manually:"
    Log "       docker restart $CaddyContainer"
    Log "=== check end ==="
    exit 1
}

Log "restarting $CaddyContainer ..."
$out = & docker restart $CaddyContainer 2>&1
foreach ($l in $out) { Log "  $l" }
if ($LASTEXITCODE -ne 0) {
    Log "ERROR: 'docker restart $CaddyContainer' exited $LASTEXITCODE. Manual intervention required."
    Log "=== check end ==="
    exit 1
}

$deadline = (Get-Date).AddSeconds(90)
$newCert = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    try { $newCert = Get-ServedCertificate -SniHost $GatewayHostname -TcpPort $Port; break } catch { }
}
if (-not $newCert) {
    Log "ERROR: :$Port did not answer within 90s after the restart. Check 'docker logs $CaddyContainer'."
    Log "=== check end ==="
    exit 1
}

$newRemaining = $newCert.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()
Log ("new leaf: NotAfter={0}Z remaining={1:N1}h" -f `
     $newCert.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), $newRemaining.TotalHours)

if ($newRemaining.TotalHours -lt $MinHoursRemaining) {
    Log "ERROR: still below the threshold after a restart. Caddy cannot issue a certificate --"
    Log "       inspect 'docker logs $CaddyContainer' (disk full, read-only volume, bad Caddyfile)."
    Log "=== check end ==="
    exit 1
}

Log "FIXED: fresh certificate issued and served."
Log "=== check end ==="
exit 0
'@

# --- 1. Write the check script -----------------------------------------------
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

# --- 2. Register the Scheduled Task ------------------------------------------
$psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = (Get-Command powershell).Source }

$argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$checkPath`"" +
           " -ComposeDir `"$InstallDir`" -CaddyContainer `"$CaddyContainer`"" +
           " -MinHoursRemaining $MinHoursRemaining"
$action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine

# Two triggers: one right after boot (the reboot that killed the volume is
# exactly when the damage happens, so check early), and a repeating one.
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT5M'   # after the autostart task has brought the stack up

# -RepetitionDuration ([TimeSpan]::MaxValue) is the documented "forever" idiom
# but throws on some Windows builds; 10 years is indefinite in practice and
# registers everywhere.
$repeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) `
    -RepetitionInterval (New-TimeSpan -Hours $IntervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

# SYSTEM: no password to store, and no user profile needed (the engine is
# already running by the time this fires).
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

# Idempotent: drop an existing task with the same name first.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Write-Host "Registering '$TaskName' (SYSTEM, every $IntervalHours h + at startup)..."
Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($bootTrigger, $repeatTrigger) -Settings $settings `
    -Principal $principal | Out-Null

# --- 3. One inline read-only pass so the operator sees the current state ------
# -CheckOnly never restarts, so this is safe to run mid-install. It exits 1 when
# something is already wrong -- report it, but don't fail the setup over it.
Write-Host ''
Write-Host 'Current certificate state:'
& $checkPath -ComposeDir $InstallDir -CaddyContainer $CaddyContainer `
    -MinHoursRemaining $MinHoursRemaining -CheckOnly
$checkExit = $LASTEXITCODE

Write-Host ''
if ($checkExit -eq 0) {
    Write-Host "Done. The certificate is healthy and will be watched every $IntervalHours h." -ForegroundColor Green
} else {
    Write-Host "Done -- but the check above reported a problem." -ForegroundColor Yellow
    Write-Host "Fix it now with:  docker restart $CaddyContainer"
    Write-Host "(or let the task do it at its next run)"
}
Write-Host ''
Write-Host "Run it on demand:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Log:                $(Join-Path $InstallDir 'autostart.log')  (lines tagged [tls-watchdog])"
Write-Host "Remove later with:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
