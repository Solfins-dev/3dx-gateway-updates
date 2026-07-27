# check-tls-cert.ps1
# ---------------------------------------------------------------------------
# TLS certificate watchdog for the 3DX Gateway Caddy container.
#
# Problem this solves (delmiaworks04, 2026-07-03 -> 2026-07-27):
# An unclean host shutdown lost files out of the caddy_data volume -- the
# leaf's PRIVATE KEY under /data/caddy/certificates/ and the contents of
# /data/caddy/locks/. Caddy itself survived: it kept listening on :443 and kept
# serving the certificate it already had in its in-memory cache, so the site
# stayed up and the app answered 200. But every renewal attempt failed with
#
#   tls.cache.maintenance  error while checking if stored certificate is also
#   expiring soon ... open /data/caddy/certificates/local/<host>/<host>.key:
#   no such file or directory
#
# every 600s. `tls internal` leafs live 12h, so ~8h after the crash the served
# cert expired and every browser showed "Not secure" -- for 23 days, because
# the only signal was a log line nobody reads. Fix was `docker restart`, which
# rebuilds the store and issues a fresh leaf.
#
# On Windows this is not a freak event: the volume lives in Docker Desktop's
# WSL2 VHDX, and Windows kills that VM on ordinary Windows Update reboots as
# well as on power loss (three ungraceful container terminations on that box in
# one month). Postgres survives via WAL replay; Caddy has no equivalent.
#
# So this script checks BOTH the symptom and the cause:
#   1. Expiry   -- the leaf actually served on the wire, i.e. exactly what a
#                  browser sees. Restart when it has less than -MinHoursRemaining
#                  left (or already expired).
#   2. Storage  -- the private key file backing that cert exists in the volume.
#                  This is the leading indicator: it catches the corruption
#                  hours BEFORE the cached cert expires, so a restart lands
#                  while the site is still healthy and nobody ever sees a
#                  warning.
# Either condition triggers `docker restart` of the Caddy container.
#
# Run by the "3DX Gateway TLS Watchdog" Scheduled Task (see
# setup-cert-watchdog.ps1). Appends to <ComposeDir>\autostart.log, the same
# post-mortem log the boot script writes, prefixed [tls-watchdog].
#
# ASCII-only on purpose (PS 5.1 misparses non-ASCII depending on host codepage).
# ---------------------------------------------------------------------------

param(
    [string]$ComposeDir      = 'C:\ProgramData\3DX-Gateway',
    [string]$CaddyContainer  = '3dx-gateway-caddy',
    # Both default to the values install.ps1 wrote into <ComposeDir>\.env
    # (HOSTNAME / APP_PORT). Pass them only for a non-standard install.
    [string]$GatewayHostname = '',
    [int]$Port               = 0,
    [int]$MinHoursRemaining  = 2,
    # Report only -- never restart. Used by the installer for a first-run
    # sanity check, and handy for manual triage.
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'
$LogFile = Join-Path $ComposeDir 'autostart.log'

function Log([string]$m) {
    $line = "{0}  [tls-watchdog] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m
    Write-Output $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
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

$cert = $null
try {
    $cert = Get-ServedCertificate -SniHost $GatewayHostname -TcpPort $Port
} catch {
    Log "ERROR: cannot complete a TLS handshake on 127.0.0.1:$Port ($($_.Exception.Message))."
    Log "       Caddy is not listening. That is the autostart task's job, not this one -- check"
    Log "       'docker compose ps' and the boot log above. No restart attempted."
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

# --- 2. Is the key that backs it still in the volume? ------------------------
# The leading indicator. Issuer-agnostic glob: 'local' for `tls internal`,
# an acme-v02 directory for Let's Encrypt.
$storeBad = $false
$dockerOk = $true
$verLine = & docker version --format '{{.Server.Version}}' 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verLine)) {
    # Same failure mode the Apply Update worker guards against: docker.exe
    # resolves but the engine is unreachable for THIS account (SYSTEM, named
    # pipe ACL, engine not started). Skip the store probe; the expiry check
    # above already ran and does not need Docker.
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
    Log "=== check end ==="
    exit 0
}

if ($CheckOnly) {
    Log "-CheckOnly: a restart of '$CaddyContainer' is what would fix this. Not restarting."
    Log "=== check end ==="
    exit 1
}

# --- 3. Repair: restart Caddy ------------------------------------------------
# On startup Caddy re-reads its storage and runs certificate maintenance
# immediately, which reissues anything expired/missing. Cost is a few seconds
# of refused connections on :443 -- far cheaper than the alternative.
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

# Wait for the listener to come back, then re-inspect. Verifying the FIX is the
# point: a restart that silently produced another bad cert must still be loud.
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
