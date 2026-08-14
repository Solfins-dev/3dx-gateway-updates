# ============================================================================
# GENERATED FILE -- DO NOT EDIT.
# Built by scripts/build-installers.ps1 from:
#   scripts/uninstall-native.ps1  sha256=2fb037fbab0399785954c5d5515580c2b89bd9c8e104c0107b9cf8e7e286e7d1
#   scripts/lib/common.ps1  sha256=dfd93c66aaf0070c536af25af94cc85fffc1406ba113dba19053671e1422625e
# Edit those, then re-run:  pwsh scripts/build-installers.ps1
# This is the file customers download; the repo copy dot-sources lib\ instead.
# ============================================================================
<#
.SYNOPSIS
Remove a native (ADR-030) 3DX Gateway install. The seatbelt for the pilot.

.DESCRIPTION
Written before the first real install, on purpose: the two steps most likely to
fail on a first run -- `pg_ctl register` and the WinSW registration -- are the
two that leave services behind, and a half-installed gateway on someone else's
server is not a thing to clean up by hand under time pressure.

Removes, in dependency order: the three services (backend, proxy via WinSW's own
uninstall, database via `pg_ctl unregister`), the firewall rules, the install
tree, and -- only when asked -- the data directory.

DATA IS KEPT BY DEFAULT. `-RemoveData` is required to delete the database, the
seed and the local CA, and it asks again unless -Yes. Deleting the CA means a
physical round of every workstation to import a new one; deleting the seed makes
every stored ERP credential unrecoverable even if the database survives.

This NEVER touches the Docker install, IIS, or anything it did not create.

.EXAMPLE
PS> .\uninstall-native.ps1
PS> .\uninstall-native.ps1 -RemoveData -Yes
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\3DX Gateway',
    [string]$DataDir    = 'C:\ProgramData\3DX-Gateway',
    [switch]$RemoveData,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

#--- BEGIN inlined scripts/lib/common.ps1 -----------------------------------
<#
Shared installer helpers -- dot-sourced by BOTH delivery paths.

  scripts/install.ps1         Docker Desktop / containers (existing, proven)
  scripts/install-native.ps1  Windows services, no containers (ADR-030)

ADR-030 accepts two permanent delivery paths. It does NOT accept two copies of
the same logic drifting apart, so anything that is genuinely common lives here:
port probing, prompts, secret generation, ACLs, and the Caddyfile generator.

RULES for this file:
  * No Docker. No compose. Nothing that only one delivery path can satisfy.
  * No $Script:Eff* reads. Everything comes in as a parameter and goes out as a
    return value -- the callers own their own state.
  * Nothing executes at load time. Dot-sourcing this file must have no effect
    beyond defining functions.

Dot-source it with:
    . (Join-Path $PSScriptRoot 'lib\common.ps1')
#>

#--- Output helpers ---------------------------------------------------------

function Write-Step    { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Substep { param([string]$Text) Write-Host "    $Text" }
function Write-Ok      { param([string]$Text) Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Text) Write-Host "    [X]  $Text" -ForegroundColor Red }
function Throw-Stop    { param([string]$Text) Write-Fail $Text; throw $Text }
function Write-Hr      { Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray }

#--- Elevation --------------------------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

#--- Native commands --------------------------------------------------------

function Invoke-Native {
    <#
    .SYNOPSIS
    Run a native executable without letting its stderr abort the script.

    .DESCRIPTION
    Windows PowerShell 5.1 turns every stderr line a native program writes into
    an ErrorRecord, and under $ErrorActionPreference = 'Stop' the first one is a
    TERMINATING error. docker, initdb, pg_ctl and WinSW all write ordinary
    progress to stderr.

    Hit live on delmiaworks04, 2026-08-11: `docker compose stop` printed
    "Container 3dx-gateway-caddy Stopping", the suspend script died on that line,
    and the stack was left half-stopped with its scheduled tasks already
    disabled -- the worst of both states.

    PS7's $PSNativeCommandUseErrorActionPreference does not help, because it does
    not exist in 5.1, and 5.1 is what a Windows Server has out of the box.

    Returns the process exit code. Output lines (both streams, in order) go to
    -OnOutput when given.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [scriptblock]$OnOutput
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            if ($OnOutput) { & $OnOutput $line }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-RestInsecure {
    <#
    Fetch a URL without validating the certificate. Used only against our own
    loopback/localhost endpoints during a smoke test, where the local CA is not
    yet trusted ON THE SERVER ITSELF (certificate trust is a workstation
    concern).

    -SkipCertificateCheck is PowerShell 7+. On 5.1 the usual scriptblock
    callback is a trap this project has already paid for: the callback runs on a
    TLS worker thread with no PowerShell runspace attached and throws
    "There is no Runspace available". A compiled ICertificatePolicy has no such
    affinity, so that is what 5.1 gets.
    #>
    param([string]$Uri, [int]$TimeoutSec = 10)

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -SkipCertificateCheck
    }

    if (-not ('BomExplorerTrustAllCerts' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BomExplorerTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
'@
    }
    $prevPolicy   = [System.Net.ServicePointManager]::CertificatePolicy
    $prevProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object BomExplorerTrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
    try {
        return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing
    } finally {
        [System.Net.ServicePointManager]::CertificatePolicy = $prevPolicy
        [System.Net.ServicePointManager]::SecurityProtocol  = $prevProtocol
    }
}

#--- Port probing -----------------------------------------------------------

function Test-PortFree {
    param([int]$P)
    $conn = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    return ($null -eq $conn -or $conn.Count -eq 0)
}

function Get-ExcludedPortRanges {
    # TCP port ranges Windows has RESERVED (WinNAT / Hyper-V / http.sys). A port
    # inside one of these cannot be bound even when nothing is currently
    # listening -- the bind fails with WSAEACCES. On a Windows Server these
    # ranges routinely swallow 80.
    # Parse `netsh interface ipv4 show excludedportrange protocol=tcp`.
    $ranges = @()
    try {
        $out = & netsh interface ipv4 show excludedportrange protocol=tcp 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*(\d+)\s+(\d+)') {
                $ranges += [pscustomobject]@{ Start = [int]$Matches[1]; End = [int]$Matches[2] }
            }
        }
    } catch { }
    return $ranges
}

function Test-PortExcluded {
    param([int]$P, $Ranges)
    if (-not $Ranges) { return $false }
    foreach ($r in $Ranges) {
        if ($P -ge $r.Start -and $P -le $r.End) { return $true }
    }
    return $false
}

function Test-PortBindable {
    # Bindable = nothing is listening AND it isn't inside a reserved/excluded
    # TCP range. The exclusion check is the non-obvious half: WinNAT and http.sys
    # reserve ranges (often covering 80) that fail to bind with WSAEACCES even
    # though Get-NetTCPConnection shows no listener. Pass a cached $Ranges to
    # avoid re-shelling netsh on every probe.
    param([int]$P, $Ranges = $null)
    if (-not (Test-PortFree -P $P)) { return $false }
    if ($null -eq $Ranges) { $Ranges = Get-ExcludedPortRanges }
    if (Test-PortExcluded -P $P -Ranges $Ranges) { return $false }
    return $true
}

function Get-PortOwner {
    # Best-effort human description of what holds a TCP port. READ-ONLY -- the
    # installer never stops whatever it finds. PID 4 / "System" means the port
    # lives in http.sys (the kernel HTTP stack), which on a Windows Server is
    # almost always IIS (W3SVC) or WinRM, not a stoppable user process.
    param([int]$P)
    $owners = @()
    $conns = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        $procName = try { (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { 'unknown' }
        if ($c.OwningProcess -eq 4 -or $procName -eq 'System') {
            $owners += 'http.sys/kernel (PID 4 System -- usually IIS/W3SVC or WinRM)'
        } else {
            $owners += "$procName (PID $($c.OwningProcess))"
        }
    }
    $owners = @($owners | Select-Object -Unique)
    if ($owners.Count -eq 0) { return $null }
    return ($owners -join ', ')
}

function Show-ServerPortPreflight {
    # Read-only lay-of-the-land for the operator. Both installers ASSUME the
    # server may already be serving production (IIS/DelmiaWorks on 80/443/8080)
    # and work AROUND it -- neither ever stops another service.
    param([int[]]$Ports = @(80, 443, 8080))
    Write-Step "Scanning ports already in use (read-only; nothing is stopped)"
    $ranges = Get-ExcludedPortRanges
    foreach ($p in $Ports) {
        $owner = Get-PortOwner -P $p
        if ($owner) {
            Write-Warn2 "Port $p is in use by $owner"
        } elseif (Test-PortExcluded -P $p -Ranges $ranges) {
            Write-Warn2 "Port $p is inside a reserved TCP range (WinNAT/http.sys)"
        } else {
            Write-Substep "Port $p is free"
        }
    }
    # IIS is the usual owner of 80/443 on a Windows Server. Get-Website only
    # exists when the WebAdministration module / IIS is present; absence is fine.
    try {
        $sites = Get-Website -ErrorAction SilentlyContinue
        if ($sites) {
            Write-Substep "IIS detected -- the installer will pick free ports around it, never stop it:"
            foreach ($s in $sites) {
                $binds = ($s.bindings.Collection.bindingInformation -join ', ')
                Write-Substep "  IIS site '$($s.Name)' state=$($s.State) bindings=$binds"
            }
        }
    } catch { }
    Write-Substep "Gateway ports are auto-selected from what's free; IIS and other services are left untouched."
}

function Find-FreePort {
    # First bindable port at or after $Start, skipping anything in $Avoid.
    # Used by the native installer for Postgres (:5432 may belong to another
    # application on a shared server) and for the backend's loopback listener.
    param([int]$Start, [int]$Tries = 40, [int[]]$Avoid = @())
    $ranges = Get-ExcludedPortRanges
    for ($p = $Start; $p -lt $Start + $Tries; $p++) {
        if ($Avoid -contains $p) { continue }
        if (Test-PortBindable -P $p -Ranges $ranges) { return $p }
    }
    return 0
}

#--- Interactive prompts ----------------------------------------------------

# Both installers accept -Yes. Call this once, at the top, so the prompt
# helpers below know whether they are allowed to block on Read-Host.
$Script:PromptAssumeYes = $false
function Set-PromptDefaults {
    param([bool]$AssumeYes)
    $Script:PromptAssumeYes = $AssumeYes
}

# Returns 'y' or 'n'. In -Yes mode answers without prompting.
#
# -UnattendedDefault separates two things that look the same and are not:
#
#   $Default            what a human gets by pressing Enter. For a destructive
#                       question that must be 'n'.
#   -UnattendedDefault  what -Yes answers. For a question the operator has
#                       ALREADY answered by typing -Yes, that must be 'y'.
#
# Collapsing them made `uninstall-native.ps1 -RemoveData -Yes` abort every time
# -- both its prompts default to 'n' by design, so -Yes returned 'n' and the
# script reported "Aborted." as though the operator had declined. Found live on
# delmiaworks04, 2026-08-12. Defaults to $Default so every existing caller keeps
# its current behaviour, including install.ps1's deliberate "don't do the
# optional risky thing unattended" cases.
function Read-YesNo {
    param([string]$Question, [string]$Default = 'y', [string]$UnattendedDefault)
    if ($Script:PromptAssumeYes) {
        return $(if ($UnattendedDefault) { $UnattendedDefault } else { $Default })
    }
    $hint = if ($Default -eq 'n') { '[y/N]' } else { '[Y/n]' }
    $answer = Read-Host "    $Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    if ($answer -match '^(y|yes)$') { return 'y' } else { return 'n' }
}

function Read-TextPrompt {
    param([string]$Question, [string]$Default = '')
    if ($Script:PromptAssumeYes) { return $Default }
    $hint = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "    $Question$hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

#--- Secrets ----------------------------------------------------------------

function New-RandomHex {
    # Cryptographic entropy, hex-encoded. Get-Random is NOT suitable here.
    param([int]$Bytes = 16)
    $buf = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buf)
    return (($buf | ForEach-Object { '{0:x2}' -f $_ }) -join '')
}

function Get-EnvFileValue {
    # Read one KEY=value out of a dotenv-style file. Returns $null when the file
    # or the key is absent. Used to PRESERVE an existing CONFIG_PROTECTOR_SEED
    # across re-installs: without the original seed every `ENC:` value in
    # appsettings.json decrypts to an empty string, silently.
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    $line = Get-Content $Path -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1]
}

function Protect-SecretFile {
    # Lock a file holding secrets to SYSTEM + Administrators only, with
    # inheritance broken. This matters far more on the native install than in
    # Docker: ADR-030's server is SHARED with other applications, and the file
    # holds CONFIG_PROTECTOR_SEED, which decrypts every stored ERP credential.
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)   # break inheritance, drop inherited ACEs
    foreach ($existing in @($acl.Access)) { [void]$acl.RemoveAccessRule($existing) }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {   # LocalSystem, BUILTIN\Administrators
        $account = (New-Object System.Security.Principal.SecurityIdentifier($sid))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account, 'FullControl', 'None', 'None', 'Allow')))
    }
    Set-Acl -Path $Path -AclObject $acl
}

#--- Caddyfile --------------------------------------------------------------

function New-CaddyfileText {
    <#
    .SYNOPSIS
    Generate the Caddyfile text for either delivery path. Returns a string; the
    caller decides where to write it.

    .PARAMETER Upstream
    What Caddy reverse-proxies to. Docker: 'app:5000' (compose DNS).
    Native: '127.0.0.1:5000' (the backend service's loopback listener).

    .PARAMETER CaddyDataRoot
    Caddy's data directory as CADDY SEES IT. Docker: '/data/caddy' (the volume
    mount). Native: e.g. 'C:\ProgramData\3DX-Gateway\data\caddy'. Only used to
    locate the local CA root that workstations download.

    .PARAMETER HttpPort
    0 = no HTTP site at all (the host has no free HTTP port). Otherwise an
    explicit http:// site is emitted so first-time workstations can fetch the CA.

    .PARAMETER EmitStorage
    Emit a global `storage file_system` pointing at -CaddyDataRoot, so Caddy
    STORES the local CA exactly where the /caddy-ca.crt handler READS it.
    Native-only; see the comment on $storageLine for why Docker must not have it.
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$HttpPort = 0,
        [ValidateSet('auto', 'letsencrypt', 'none')][string]$Tls = 'auto',
        [Parameter(Mandatory)][string]$Upstream,
        [string]$CaddyDataRoot = '/data/caddy',
        [string]$BindAddress = '',
        [switch]$EmitSitePorts,
        [switch]$DisableAdminApi,
        [switch]$EmitStorage
    )

    # A Caddy site address WITHOUT a port means the standard ports: 443 for an
    # HTTPS site, 80 for an http:// one. Under Docker that is exactly right --
    # compose maps 9443:443, so Caddy always listens on 443 inside the container
    # and the host port is somebody else's problem.
    #
    # Natively NOTHING remaps anything. A portless site address makes Caddy bind
    # 443 no matter what -Port said, so the gateway answers on the wrong port,
    # and on a shared server it silently claims a port it was never given.
    # Observed on delmiaworks04 2026-08-11: everything installed, the proxy
    # service ran, and :9443 was dead because Caddy was sitting on :443.
    #
    # -EmitSitePorts is therefore OFF by default (the Docker output stays
    # byte-identical, which Test-CaddyfileParity.ps1 enforces) and ON for the
    # native installer.
    $httpsSiteAddr = if ($EmitSitePorts) { "${HostName}:$Port" } else { $HostName }
    $httpSiteAddr  = if ($EmitSitePorts) { "http://${HostName}:$HttpPort" } else { "http://$HostName" }

    # Redirect target for the HTTP->HTTPS site. Include the explicit port when
    # the app port isn't the standard 443 (auto-fallback may have moved it).
    $redirTarget = if ($Port -eq 443) { "https://$HostName" } else { "https://${HostName}:$Port" }

    # The local-CA download handler, reused in either the :80 site (normal) or
    # the HTTPS site (when no HTTP port is available).
    # Forward slashes, always. Caddy accepts them on Windows, and the Caddyfile
    # parser treats `\` as an escape character -- a native path pasted in raw
    # ("C:\ProgramData\...") is a parse hazard, not merely ugly. Quote the token
    # if the path contains whitespace.
    $dataRoot = $CaddyDataRoot.TrimEnd('/', '\') -replace '\\', '/'
    $caRoot = $dataRoot + '/pki/authorities/local'
    if ($caRoot -match '\s') { $caRoot = '"' + $caRoot + '"' }
    $caHandler = @"
    handle /caddy-ca.crt {
        root * $caRoot
        rewrite * /root.crt
        file_server
    }
"@

    # ADR-030 finding 4: a Caddy site address does NOT bind an interface, it
    # filters the Host header -- `:8099` listens on EVERY interface and
    # `127.0.0.1:8099` returns 400 instead of binding loopback. Only the `bind`
    # directive controls the listener. On a shared server that difference is the
    # difference between exposing the gateway to the LAN and not.
    $bindLine = if ($BindAddress) { "    bind $BindAddress`n" } else { '' }

    if ($Tls -eq 'letsencrypt') {
        return @"
$httpsSiteAddr {
$bindLine    reverse_proxy $Upstream
}
"@
    }

    # auto (local CA). Mirrors scripts/install.sh's proven Caddyfile:
    #  - Global `auto_https disable_redirects`: Caddy auto-adds an HTTP->HTTPS
    #    redirect for any host that has an HTTPS site, and that auto-redirect
    #    WINS hostname matching for /caddy-ca.crt on the HTTP port (308 to
    #    HTTPS), which a workstation can't follow before it trusts the CA ->
    #    0-byte download -> Setup aborts. Disabling it lets our explicit HTTP
    #    site serve the CA. Cert management itself is unaffected.
    #  - The CA is exposed by an EXPLICIT `http://<host>` site, NOT a bare
    #    `:80` (which auto-HTTPS still shadows for the matching hostname).
    #  - The redirect lives in a catch-all `handle {}` so the more specific
    #    `handle /caddy-ca.crt` wins (Caddy orders top-level `redir` before
    #    `handle`).
    #  - We ALSO keep the CA handler on the HTTPS site so CadBridge's HTTPS
    #    (TOFU/curl) fallback works when the host's HTTP port is taken or
    #    remapped (e.g. 8081 behind IIS) -- Windows-specific belt-and-braces.
    # `admin off` closes Caddy's configuration API. It listens on 127.0.0.1:2019
    # by default and has NO authentication: any local process can POST a new
    # configuration, reroute traffic or read the certificates. Inside a container
    # that port is sealed in the container's own namespace, which is why the
    # Docker delivery never had to care. On ADR-030's SHARED Windows server it is
    # reachable by every local account, so the native installer turns it off --
    # nothing here uses it. (Observed live on delmiaworks04 2026-08-11.)
    $adminLine = if ($DisableAdminApi) { "    admin off`n" } else { '' }

    # WHERE CADDY STORES THE LOCAL CA, stated explicitly instead of inherited.
    #
    # Caddy resolves its data directory through caddy.AppDataDir(): XDG_DATA_HOME
    # (+ "/caddy") if set, else %AppData%\Caddy on Windows, else ~/.local/share/caddy.
    # The official caddy Docker image sets XDG_DATA_HOME=/data, which is the ONLY
    # reason the Docker path's hard-coded /data/caddy handler ever found root.crt.
    # Natively nothing sets it: the proxy runs as LocalSystem, so Caddy wrote its
    # CA to C:\Windows\System32\config\systemprofile\AppData\Roaming\Caddy while
    # the handler below served an empty ProgramData directory -- /caddy-ca.crt
    # returned 404 and CadBridge Setup could not bootstrap trust at all.
    # (Observed live on delmiaworks04 2026-08-14, root.crt found in systemprofile.)
    #
    # The installer originally tried to steer this with <env name="CADDY_DATA_DIR">,
    # a variable Caddy does not read. A wrong env var name is nobody's error: it
    # fails silently, which is exactly how this survived Phase 2 AND Phase 3.
    # So the path is declared HERE, in the same file as the handler that reads it
    # -- the two cannot drift, and no environment is involved.
    #
    # Docker must NOT get this line: its Caddyfile is byte-frozen by
    # Test-CaddyfileParity.ps1, and there XDG_DATA_HOME already resolves correctly.
    $storageLine = if ($EmitStorage) {
        $sp = if ($dataRoot -match '\s') { '"' + $dataRoot + '"' } else { $dataRoot }
        "    storage file_system $sp`n"
    } else { '' }

    $globalBlock = @"
{
$adminLine$storageLine    auto_https disable_redirects
}
"@
    $httpsSite = @"
$httpsSiteAddr {
$bindLine    tls internal
$caHandler
    handle {
        reverse_proxy $Upstream
    }
}
"@
    if ($HttpPort -ne 0) {
        return @"
$globalBlock

$httpsSite

# Expose the local CA over HTTP so first-time workstations can fetch it.
$httpSiteAddr {
$bindLine$caHandler
    handle {
        redir $redirTarget{uri}
    }
}
"@
    }
    return @"
$globalBlock

$httpsSite
"@
}


#--- END inlined scripts/lib/common.ps1 -------------------------------------
Set-PromptDefaults -AssumeYes $Yes.IsPresent

$SVC_APP   = '3DXGateway'
$SVC_DB    = '3DXGatewayDb'
$SVC_PROXY = '3DXGatewayProxy'

if (-not (Test-IsAdmin)) { Throw-Stop 'Run elevated.' }

Write-Host ''
Write-Host '3DX Gateway -- native uninstall' -ForegroundColor Cyan
Write-Host ''

# Refuse to run against a Docker install's directory. Same collision the
# installer guards against, and here the consequence would be worse: deleting a
# running stack's .env and Caddyfile.
foreach ($marker in @('docker-compose.yml', 'compose-set.json')) {
    if (Test-Path (Join-Path $DataDir $marker)) {
        Throw-Stop "$DataDir holds a DOCKER install ($marker). This uninstaller is for the native install only -- use scripts/uninstall.ps1 for that one."
    }
}

$found = @($SVC_APP, $SVC_DB, $SVC_PROXY | Where-Object { Get-Service $_ -ErrorAction SilentlyContinue })
if (-not $found -and -not (Test-Path $InstallDir)) {
    Write-Ok 'Nothing to remove.'
    return
}
Write-Substep "Services present: $(if ($found) { $found -join ', ' } else { '(none)' })"
Write-Substep "Install tree: $(if (Test-Path $InstallDir) { $InstallDir } else { '(none)' })"
Write-Substep "Data: $DataDir  -- $(if ($RemoveData) { 'WILL BE DELETED' } else { 'kept' })"
Write-Host ''

# Default 'n' for a human at the keyboard; 'y' for -Yes, which IS the answer.
if ((Read-YesNo 'Proceed?' 'n' -UnattendedDefault 'y') -ne 'y') { Write-Substep 'Aborted.'; return }

#--- Services ---------------------------------------------------------------

Write-Step 'Stopping services'
foreach ($svc in @($SVC_PROXY, $SVC_APP, $SVC_DB)) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $s) { continue }
    if ($s.Status -ne 'Stopped') {
        try { Stop-Service $svc -Force -ErrorAction Stop; Write-Ok "$svc stopped" }
        catch { Write-Warn2 "$svc did not stop cleanly: $($_.Exception.Message)" }
    }
}

Write-Step 'Removing services'

# Proxy: let WinSW deregister itself, so its own state goes with it. Fall back
# to sc.exe if the wrapper is gone (a half-failed install can leave exactly that).
$wrapper = Join-Path $InstallDir "caddy\$SVC_PROXY.exe"
if (Get-Service $SVC_PROXY -ErrorAction SilentlyContinue) {
    if (Test-Path $wrapper) {
        # Invoke-Native, not a bare call: PowerShell 5.1 turns a native
        # program's stderr into a terminating error under EAP=Stop, and an
        # uninstaller that dies half-way leaves exactly the mess it exists to
        # prevent. (Cost a live run on delmiaworks04, 2026-08-11.)
        [void](Invoke-Native -FilePath $wrapper -Arguments @('uninstall') -OnOutput { param($l) Write-Substep $l })
    } else {
        [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', $SVC_PROXY))
    }
    Write-Ok "$SVC_PROXY removed"
}

# Database: pg_ctl unregister, so PostgreSQL's own idea of the service goes too.
$pgCtl = Join-Path $InstallDir 'pgsql\bin\pg_ctl.exe'
if (Get-Service $SVC_DB -ErrorAction SilentlyContinue) {
    if (Test-Path $pgCtl) {
        [void](Invoke-Native -FilePath $pgCtl -Arguments @('unregister', '-N', $SVC_DB) -OnOutput { param($l) Write-Substep $l })
    } else {
        [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', $SVC_DB))
    }
    Write-Ok "$SVC_DB removed"
}

if (Get-Service $SVC_APP -ErrorAction SilentlyContinue) {
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('delete', $SVC_APP))
    Write-Ok "$SVC_APP removed"
}

# The SCM keeps a deleted service around until every handle closes. Say so,
# rather than letting a re-install fail with a confusing "already exists".
Start-Sleep -Seconds 2
$ghosts = @($SVC_APP, $SVC_DB, $SVC_PROXY | Where-Object { Get-Service $_ -ErrorAction SilentlyContinue })
if ($ghosts) {
    Write-Warn2 "Still registered (marked for deletion): $($ghosts -join ', ')"
    Write-Substep 'Close services.msc / Event Viewer if open. They disappear on the next reboot at the latest.'
}

#--- Firewall ---------------------------------------------------------------

Write-Step 'Firewall rules'
$rules = @(Get-NetFirewallRule -DisplayName '3DX Gateway TCP *' -ErrorAction SilentlyContinue)
foreach ($r in $rules) {
    Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    Write-Ok "removed '$($r.DisplayName)'"
}
if (-not $rules) { Write-Substep 'none found' }

#--- Files ------------------------------------------------------------------

Write-Step 'Files'
if (Test-Path $InstallDir) {
    # Delete the junction as a LINK first. Remove-Item -Recurse on a directory
    # containing a junction has historically followed it and deleted the target
    # contents; here the target is inside the same tree, but the habit matters:
    # in a pilot the junction may point somewhere you did not intend to lose.
    $current = Join-Path $InstallDir 'current'
    if (Test-Path $current) {
        $item = Get-Item $current -Force
        if ($item.LinkType) { $item.Delete(); Write-Substep 'junction current\ removed as a link' }
    }
    Remove-Item $InstallDir -Recurse -Force
    Write-Ok "removed $InstallDir"
}

if ($RemoveData) {
    if (Test-Path $DataDir) {
        Write-Host ''
        Write-Warn2 'About to delete the database, the ConfigProtector seed and the local CA.'
        Write-Substep 'The seed is what decrypts every stored ERP credential. The CA is imported on every workstation.'
        # `-RemoveData -Yes` is documented as "delete without asking again", so
        # that combination must actually delete. A human still gets 'n' on Enter.
        if ((Read-YesNo "Delete $DataDir permanently?" 'n' -UnattendedDefault 'y') -ne 'y') {
            Write-Substep 'Data kept.'
        } else {
            Remove-Item $DataDir -Recurse -Force
            Write-Ok "removed $DataDir"
        }
    }
} elseif (Test-Path $DataDir) {
    Write-Ok "kept $DataDir (database, seed, certificates, logs)"
    Write-Substep 'A re-install into the same DataDir reuses the seed, so ENC: values keep working.'
}

Write-Host ''
Write-Hr
Write-Host ''
Write-Host '  Native install removed.' -ForegroundColor Green
if (-not $RemoveData) { Write-Host "  Data left at $DataDir" }
Write-Host ''
