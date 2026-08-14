#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-off repair for native (ADR-030) installs made before 2026-08-14:
    point Caddy's storage at the directory the /caddy-ca.crt handler reads,
    and MOVE the existing local CA there instead of letting a second one appear.

.DESCRIPTION
    install-native.ps1 used to steer Caddy's data directory with
    <env name="CADDY_DATA_DIR">, a variable Caddy does not read. Caddy therefore
    resolved its own default -- %AppData%\Caddy, which for a LocalSystem service
    is C:\Windows\System32\config\systemprofile\AppData\Roaming\Caddy -- while
    the Caddyfile served root.crt out of <DataDir>\data\caddy, which stayed
    empty. Result: GET /caddy-ca.crt returns 404 on both the HTTPS and the HTTP
    site, and CadBridge Setup cannot bootstrap trust on any workstation.

    The fix in the installer is `storage file_system` in the Caddyfile (plus a
    correct XDG_DATA_HOME). This script applies the same thing to an install
    that already exists, without reinstalling.

    Why MOVE rather than let Caddy re-issue: the CA is the trust anchor every
    workstation imports once. Leaving the old tree behind and starting a fresh
    one produces two roots with the same subject name on the same network, which
    is a genuinely confusing failure to diagnose (we have had it before: the
    browser reports "Not secure" against a certificate that looks perfectly
    valid, because the trusted root is the OTHER one with the same CN).

    Idempotent: re-running after a successful repair changes nothing.

.PARAMETER DataDir
    The install's data directory -- the one holding Caddyfile and data\caddy.

.PARAMETER ServiceName
    The Caddy service. Default 3DXGatewayProxy.

.PARAMETER WhatIfOnly
    Report what would change and exit without touching anything.

.EXAMPLE
    PS> .\repair-native-ca-storage.ps1 -DataDir C:\ProgramData\3DX-Gateway-Native
#>
[CmdletBinding()]
param(
    [string]$DataDir     = 'C:\ProgramData\3DX-Gateway',
    [string]$ServiceName = '3DXGatewayProxy',
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

function Say  { param($m) Write-Host "  $m" }
function Ok   { param($m) Write-Host "  OK   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  WARN $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "  STOP $m" -ForegroundColor Red; exit 1 }

$caddyfile = Join-Path $DataDir 'Caddyfile'
$dataCaddy = Join-Path $DataDir 'data\caddy'
$wrongRoot = Join-Path $env:SystemRoot 'System32\config\systemprofile\AppData\Roaming\Caddy'

Write-Host ''
Write-Host "Native CA storage repair" -ForegroundColor Cyan
Write-Host "  DataDir     $DataDir"
Write-Host "  Storage     $dataCaddy"
Write-Host "  Stray CA    $wrongRoot"
Write-Host ''

if (-not (Test-Path $caddyfile)) { Die "No Caddyfile at $caddyfile -- is -DataDir right?" }

# --- What is actually wrong here? Establish it, do not assume. --------------
$text = Get-Content -Raw $caddyfile
$hasStorage = $text -match '(?m)^\s*storage\s+file_system\s'
$liveCa     = Join-Path $dataCaddy 'pki\authorities\local\root.crt'
$strayCa    = Join-Path $wrongRoot 'pki\authorities\local\root.crt'

Say ("Caddyfile declares storage : " + $(if ($hasStorage) { 'yes' } else { 'NO' }))
Say ("CA present in storage dir  : " + $(if (Test-Path $liveCa)  { 'yes' } else { 'NO' }))
Say ("CA present in systemprofile: " + $(if (Test-Path $strayCa) { 'yes' } else { 'NO' }))
Write-Host ''

if ($hasStorage -and (Test-Path $liveCa) -and -not (Test-Path $strayCa)) {
    Ok 'Nothing to repair -- this install is already correct.'
    exit 0
}
if ($WhatIfOnly) { Warn 'WhatIfOnly: stopping here, nothing changed.'; exit 0 }

# --- Stop the proxy ---------------------------------------------------------
# Only the proxy. The backend and the database are untouched by this repair,
# and the gateway being briefly unreachable is enough disruption on a shared
# server without restarting services that have nothing to do with the fault.
$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) { Die "Service $ServiceName not found." }
$wasRunning = $svc.Status -eq 'Running'
if ($wasRunning) {
    Say "Stopping $ServiceName ..."
    Stop-Service $ServiceName -Force
    (Get-Service $ServiceName).WaitForStatus('Stopped', '00:00:30')
    Ok "$ServiceName stopped"
}

# --- Move the CA (and any issued certificates) into the storage directory ---
if ((Test-Path $strayCa) -and -not (Test-Path $liveCa)) {
    New-Item -ItemType Directory -Path $dataCaddy -Force | Out-Null
    foreach ($sub in 'pki', 'certificates') {
        $from = Join-Path $wrongRoot $sub
        if (-not (Test-Path $from)) { continue }
        $to = Join-Path $dataCaddy $sub
        if (Test-Path $to) { Warn "$to already exists -- leaving it alone, moving nothing for '$sub'"; continue }
        Move-Item -Path $from -Destination $to
        Ok "moved $sub -> $to"
    }
    # Fingerprint what we moved, so the operator can compare it against what a
    # workstation has already imported instead of taking "moved" on faith.
    if (Test-Path $liveCa) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($liveCa)
        Ok ("CA preserved: {0}  thumbprint {1}  expires {2}" -f $cert.Subject, $cert.Thumbprint, $cert.NotAfter)
    }
} elseif ((Test-Path $strayCa) -and (Test-Path $liveCa)) {
    Warn 'A CA exists in BOTH places. Not guessing which one workstations trust.'
    Warn "Compare thumbprints by hand, keep the imported one, then delete the other:"
    Warn "  $strayCa"
    Warn "  $liveCa"
} elseif (-not (Test-Path $liveCa)) {
    Warn 'No CA found in either location -- Caddy will issue a fresh one on start.'
    Warn 'Every workstation must then re-import /caddy-ca.crt.'
}

# --- Declare the storage path in the Caddyfile ------------------------------
# Forward slashes: the Caddyfile parser treats \ as an escape character.
if (-not $hasStorage) {
    $storagePath = ($dataCaddy.TrimEnd('\', '/') -replace '\\', '/')
    if ($storagePath -match '\s') { $storagePath = '"' + $storagePath + '"' }
    $line = "    storage file_system $storagePath"

    if ($text -match '(?m)^\{\s*$') {
        # Insert into the existing global options block, as its first entry.
        $patched = [regex]::Replace($text, '(?m)^\{[ \t]*\r?\n', "{`r`n$line`r`n", 1)
    } else {
        # No global block at all (e.g. a letsencrypt install) -- prepend one.
        $patched = "{`r`n$line`r`n}`r`n`r`n" + $text
    }
    if ($patched -eq $text) { Die "Could not patch the Caddyfile -- edit it by hand and add: $line" }

    Copy-Item $caddyfile "$caddyfile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Set-Content -Path $caddyfile -Value $patched -Encoding UTF8 -NoNewline
    Ok "Caddyfile patched (original kept as .bak-*)"
}

# --- Correct the WinSW environment too --------------------------------------
# Not what makes the fix work -- the Caddyfile does that -- but it stops a
# hand-run caddy.exe on this box from creating a THIRD tree somewhere else.
# Caddy appends "caddy" to XDG_DATA_HOME, so the value is the PARENT directory.
$xml = $null
foreach ($root in @('C:\Program Files\3DX Gateway\caddy', 'C:\Program Files\3DX Gateway', 'C:\Program Files')) {
    if (-not (Test-Path $root)) { continue }
    $hit = Get-ChildItem -Path $root -Filter "$ServiceName.xml" -Recurse -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $xml = $hit.FullName; break }
}
if ($xml) {
    $xmlText = Get-Content -Raw $xml
    if ($xmlText -match 'CADDY_DATA_DIR') {
        $parent = (Split-Path -Parent $dataCaddy)
        $xmlText = $xmlText -replace '<env name="CADDY_DATA_DIR"[^/]*/>', "<env name=`"XDG_DATA_HOME`" value=`"$parent`"/>"
        Set-Content -Path $xml -Value $xmlText -Encoding UTF8
        Ok "$([IO.Path]::GetFileName($xml)): CADDY_DATA_DIR replaced with XDG_DATA_HOME=$parent"
    } else {
        Say "$([IO.Path]::GetFileName($xml)): no CADDY_DATA_DIR to replace"
    }
} else {
    Warn "Could not locate $ServiceName.xml -- skipping the env correction (harmless; the Caddyfile is what matters)."
}

# --- Restart and PROVE it ---------------------------------------------------
if ($wasRunning) {
    Say "Starting $ServiceName ..."
    Start-Service $ServiceName
    (Get-Service $ServiceName).WaitForStatus('Running', '00:00:30')
    Ok "$ServiceName running"
}

Write-Host ''
Write-Host 'Verify (the only thing that counts):' -ForegroundColor Cyan
Write-Host '  curl.exe -sk -o ca.crt -w "%{http_code} %{size_download}\n" https://<host>:<port>/caddy-ca.crt'
Write-Host '  200 and a few hundred bytes = fixed. 404 = the handler still reads an empty directory.'
Write-Host ''
