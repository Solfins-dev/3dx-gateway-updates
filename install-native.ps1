# ============================================================================
# GENERATED FILE -- DO NOT EDIT.
# Built by scripts/build-installers.ps1 from:
#   scripts/install-native.ps1  sha256=f43d09662741af8d1b596ae354fb33113b5aa4e4cc208c9f1bdb48c10d8d9c70
#   scripts/lib/common.ps1  sha256=dfd93c66aaf0070c536af25af94cc85fffc1406ba113dba19053671e1422625e
# Edit those, then re-run:  pwsh scripts/build-installers.ps1
# This is the file customers download; the repo copy dot-sources lib\ instead.
# ============================================================================
<#
.SYNOPSIS
3DX Gateway -- native Windows installer. Three Windows services, no containers.

.DESCRIPTION
ADR-030. The customer's Windows Server cannot be changed and cannot run Linux
containers, so the gateway is delivered as three Windows services:

    3DXGateway        backend, self-contained .NET 8 publish
    3DXGatewayDb      PostgreSQL 16 from the binaries zip (no MSI, no EDB installer)
    3DXGatewayProxy   caddy.exe

The server is SHARED with other applications. That constraint shapes everything
here and is not negotiable:

  * :80 belongs to IIS and stays there. This installer never binds it.
  * Every port is probed; nothing is assumed free and nothing is ever stopped.
  * No machine-wide footprint: no shared .NET runtime, no MSI, no PATH edits,
    no registry policy. One directory tree and three services.

Layout (ADR-030):

    <InstallDir>\current\           NTFS junction -> versions\<active>
    <InstallDir>\versions\<v>\      backend + wwwroot
    <InstallDir>\pgsql\             Postgres binaries (pinned)
    <InstallDir>\caddy\caddy.exe
    <DataDir>\appsettings.json .env Caddyfile  logs\  data\{pgdata,caddy,app}

State and binaries are deliberately separate: an update never touches DataDir.

.PARAMETER AppZip
The native backend artifact (self-contained publish, zipped, INCLUDING wwwroot).
OPTIONAL: when omitted, the installer reads the public manifest's `backendNative`
entry and downloads that version, verifying its sha256. Pass a local path or URL
to pin a specific artifact (no sha256 is required for a file you built yourself).

.PARAMETER ManifestUrl
Where to look for the artifact when -AppZip is omitted. Override for an air-gapped
mirror.

.PARAMETER DbLocale
initdb locale. Chosen ONCE and unchangeable without recreating the cluster.

Default 'en_US.UTF-8' because that is what the running containers actually have.
MEASURED on 2026-08-11, not reasoned about:

    select datcollate||' '||datctype from pg_database where datname=current_database()
    -> en_US.utf8 en_US.utf8

(An earlier guess that postgres:16-alpine yields a C cluster -- Alpine ships no
locales -- was simply wrong, and the query settled it. Ask the database.)

Caveat worth knowing before anyone chases a sorting bug: Windows reaches this
locale through NLS, not glibc, so ordering is linguistic and near-identical but
not guaranteed byte-for-byte equal to the Linux cluster in edge cases. For the
data here -- part names and revisions, overwhelmingly ASCII alphanumeric -- the
two agree. If a real mismatch ever appears, the portable fix is ICU
(--locale-provider=icu --icu-locale=en-US), which sorts identically on every
platform; that is a cluster recreation, so decide it before go-live, not after.

.EXAMPLE
PS> .\install-native.ps1 -AppZip C:\artifacts\3dx-gateway-1.1.71-win-x64.zip
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\3DX Gateway',
    [string]$DataDir    = 'C:\ProgramData\3DX-Gateway',
    [string]$HostName,
    [int]$Port         = 443,
    [int]$HttpPort     = 8081,
    [int]$AppPort      = 5000,
    [int]$PgPort       = 5432,
    [ValidateSet('auto', 'letsencrypt', 'none')]
    [string]$Tls       = 'auto',
    [string]$DbLocale  = 'en_US.UTF-8',
    [string]$AppZip,
    [string]$AppZipSha256,
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/latest.json',
    [string]$PostgresZip = 'https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64-binaries.zip',
    [string]$CaddyZip    = 'https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_windows_amd64.zip',
    # caddy.exe cannot be an SCM service on its own; WinSW is the wrapper Caddy's
    # own documentation points at. Pinned by version AND sha256 -- it is a
    # third-party binary that ends up on a customer's shared server.
    [string]$WinSwExe    = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe',
    [string]$License,
    [ValidateSet('on', 'off')]
    [string]$Telemetry = 'on',
    [switch]$SkipFirewall,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
# Native commands here (initdb, pg_ctl, sc.exe) are checked via $LASTEXITCODE;
# PS7's default would turn a benign non-zero exit into a terminating error
# before the check runs. Same reasoning as install.ps1.
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

$INSTALLER_VERSION = '1.0.0'

# WinSW-x64.exe v2.12.0, hashed from the GitHub release asset on 2026-08-11
# (18 243 033 bytes). If this ever mismatches, STOP: do not "fix" it by pasting
# the new hash without establishing where the different binary came from.
$WINSW_SHA256 = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'

$SVC_APP   = '3DXGateway'
$SVC_DB    = '3DXGatewayDb'
$SVC_PROXY = '3DXGatewayProxy'

$DB_NAME = 'bom_explorer'
$DB_USER = 'bomapp'

# Effective values, filled by Resolve-*
$Script:EffHostName = $null
$Script:EffPort     = 0
$Script:EffHttpPort = 0
$Script:EffAppPort  = 0
$Script:EffPgPort   = 0
$Script:EffVersion  = $null
$Script:DbPassword  = $null
$Script:Seed        = $null

#--- Paths ------------------------------------------------------------------

$P = @{}
function Initialize-Paths {
    $script:P = @{
        Versions   = Join-Path $InstallDir 'versions'
        Current    = Join-Path $InstallDir 'current'
        Pgsql      = Join-Path $InstallDir 'pgsql'
        CaddyDir   = Join-Path $InstallDir 'caddy'
        CaddyExe   = Join-Path $InstallDir 'caddy\caddy.exe'
        PgData     = Join-Path $DataDir 'data\pgdata'
        CaddyData  = Join-Path $DataDir 'data\caddy'
        AppData    = Join-Path $DataDir 'data\app'
        Logs       = Join-Path $DataDir 'logs'
        Env        = Join-Path $DataDir '.env'
        AppSettings= Join-Path $DataDir 'appsettings.json'
        Caddyfile  = Join-Path $DataDir 'Caddyfile'
        License    = Join-Path $DataDir 'license.lic'
    }
}

#--- Pre-flight -------------------------------------------------------------

function Show-Banner {
    Write-Host ''
    Write-Host "3DX Gateway native installer v$INSTALLER_VERSION (Windows services, no containers)" -ForegroundColor Cyan
    Write-Host "ADR-030. Shared-server safe: never binds :80, never stops another service." -ForegroundColor DarkGray
    Write-Host ''
}

function Test-Preflight {
    if (-not (Test-IsAdmin)) {
        Throw-Stop "Re-run from an elevated PowerShell. Registering services and writing to Program Files both need Admin."
    }
    Write-Step 'Checking OS'
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 17763) {
        Throw-Stop "Unsupported OS: $($os.Caption) (build $build). Need Windows Server 2019+ or Windows 10 21H2+."
    }
    Write-Ok "$($os.Caption) (build $build)"

    # A previous install must be dealt with deliberately, not silently upgraded
    # by an installer whose job is a FRESH install. The update path is Phase 3.
    foreach ($svc in @($SVC_APP, $SVC_DB, $SVC_PROXY)) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            Throw-Stop "Service '$svc' already exists. This installer does fresh installs only; remove the existing one first (uninstall-native.ps1, Phase 4) or use the update path."
        }
    }
    if (-not $AppZip) { Resolve-AppZipFromManifest }

    # DataDir defaults to C:\ProgramData\3DX-Gateway -- which is ALSO the Docker
    # installer's default install directory, holding the live stack's .env,
    # Caddyfile and compose set. Writing this install's .env and Caddyfile there
    # would overwrite a running production stack's configuration: the seed and
    # the Postgres password, and the proxy config, all replaced under it.
    #
    # A side-by-side pilot (ADR-030 Phase 5) is a legitimate thing to do, but it
    # gets its own DataDir, explicitly.
    foreach ($marker in @('docker-compose.yml', 'compose-set.json')) {
        if (Test-Path (Join-Path $DataDir $marker)) {
            Throw-Stop @"
$DataDir already holds a Docker install of the gateway ($marker).
This installer would overwrite its .env and Caddyfile, taking the running stack down with it.
Pass a separate location for a side-by-side pilot, e.g.
  -DataDir 'C:\ProgramData\3DX-Gateway-Native' -InstallDir 'C:\Program Files\3DX Gateway Native'
"@
        }
    }
}

function Resolve-AppZipFromManifest {
    <#
    Fill in -AppZip from the public manifest's `backendNative` entry.

    Without this the documented customer flow is "download the installer, then
    also download a 53 MB zip from a URL with a version number in it" -- an
    instruction that is wrong the day after the next release, in a document we
    cannot edit on the customer's disk. The installer knows where the manifest
    is; it should read it.

    The sha256 comes from the same entry and is passed on as MANDATORY here.
    That is the difference between this and an operator pointing -AppZip at a
    file they just built themselves: a zip fetched from the internet gets
    verified, always.

    There is deliberately NO fallback to the `backend` (container) entry. Both
    sections carry the same version number, so a fallback would look healthy
    right up to the point where this script tried to unzip a GHCR image
    reference. A manifest with no `backendNative` means there is no native
    artifact published, and saying so is the honest outcome.
    #>
    Write-Step 'Resolving the backend artifact from the manifest'
    $m = $null
    try {
        $m = Invoke-RestMethod -Uri $ManifestUrl -TimeoutSec 30 -UseBasicParsing
    } catch {
        Throw-Stop @"
Could not read the update manifest at $ManifestUrl
  $($_.Exception.Message)
Pass the artifact explicitly instead: -AppZip C:\path\3dx-gateway-<version>-win-x64.zip
"@
    }
    $native = $m.backendNative
    if (-not $native -or -not $native.downloadUrl) {
        Throw-Stop "The manifest has no 'backendNative' entry, so no native artifact is published. Pass -AppZip explicitly."
    }
    if (-not $native.sha256) {
        Throw-Stop "The manifest's 'backendNative' entry has no sha256. Refusing to install an unverified artifact."
    }
    $script:AppZip       = $native.downloadUrl
    $script:AppZipSha256 = $native.sha256
    Write-Ok "Version $($native.version) from the manifest"
    Write-Substep $native.downloadUrl
}

function Get-DefaultHostName {
    <#
    The name offered when the operator just presses Enter. Getting this wrong is
    not cosmetic: a Caddy site address FILTERS the Host header, so a gateway
    installed under the short name simply does not answer clients that use the
    FQDN -- no certificate warning, no wrong-name error, just no matching site.

    Three sources, best first:

      1. An existing gateway install's .env on this machine (Docker or native).
         If this server already serves the gateway, the name its clients, its
         certificate and every CadBridge already use is the ONLY right answer,
         and it beats anything derived from the OS.
      2. DNSHostName + the AD/DNS domain from Win32_ComputerSystem.
      3. Dns.GetHostEntry, then the bare computer name.

    (2) exists because (3) is not reliable: on delmiaworks04 -- domain-joined,
    real FQDN delmiaworks04.local.solfins.com -- GetHostEntry returned the SHORT
    name, so the default was wrong on exactly the machine this installer was
    written for (2026-08-12).
    #>
    foreach ($envFile in @(
        (Join-Path $DataDir '.env'),
        (Join-Path $env:ProgramData '3DX-Gateway\.env'))) {
        $existing = Get-EnvFileValue -Path $envFile -Key 'HOSTNAME'
        if ($existing) {
            Write-Substep "Existing install at $envFile serves '$existing' -- offering that."
            return $existing
        }
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain -and $cs.DNSHostName) {
            return "$($cs.DNSHostName).$($cs.Domain)".ToLowerInvariant()
        }
    } catch { }

    try { return [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { return $env:COMPUTERNAME }
}

function Resolve-Config {
    Write-Step 'Resolving hostname and ports'

    $Script:EffHostName = if ($HostName) { $HostName } else {
        Read-TextPrompt 'Hostname clients will use (must match the certificate and every CadBridge URL)' (Get-DefaultHostName)
    }
    if (-not $Script:EffHostName) { Throw-Stop 'A hostname is required.' }

    Show-ServerPortPreflight -Ports @(80, 443, 8080, $HttpPort)

    $ranges = Get-ExcludedPortRanges

    # HTTPS port. :80 is never a candidate -- it is IIS's on this server.
    if ($Port -eq 80 -or $HttpPort -eq 80) { Throw-Stop 'This installer never binds :80 -- it belongs to IIS on a shared server (ADR-030).' }
    $Script:EffPort = if (Test-PortBindable -P $Port -Ranges $ranges) { $Port } else { Find-FreePort -Start 8443 -Avoid @(80) }
    if ($Script:EffPort -eq 0) { Throw-Stop 'No bindable HTTPS port found.' }
    if ($Script:EffPort -ne $Port) { Write-Warn2 "Port $Port is not bindable; using $($Script:EffPort)" } else { Write-Ok "HTTPS port $($Script:EffPort)" }

    # HTTP port exists only to serve the local CA to first-time workstations.
    # 0 = none available; New-CaddyfileText then keeps the CA on the HTTPS site.
    $Script:EffHttpPort = if (Test-PortBindable -P $HttpPort -Ranges $ranges) { $HttpPort } else { Find-FreePort -Start 8082 -Avoid @(80, $Script:EffPort) }
    if ($Script:EffHttpPort -eq 0) { Write-Warn2 'No HTTP port available -- the CA will only be downloadable over HTTPS.' }
    else { Write-Ok "HTTP (CA download) port $($Script:EffHttpPort)" }

    # Loopback-only listeners. These never leave the machine.
    $Script:EffAppPort = Find-FreePort -Start $AppPort -Avoid @(80, $Script:EffPort, $Script:EffHttpPort)
    $Script:EffPgPort  = Find-FreePort -Start $PgPort  -Avoid @(80, $Script:EffPort, $Script:EffHttpPort, $Script:EffAppPort)
    if ($Script:EffAppPort -eq 0 -or $Script:EffPgPort -eq 0) { Throw-Stop 'No free loopback ports for the backend/database.' }
    Write-Ok "Backend 127.0.0.1:$($Script:EffAppPort), PostgreSQL 127.0.0.1:$($Script:EffPgPort)"
    if ($Script:EffPgPort -ne $PgPort) { Write-Substep "(:$PgPort was taken -- another application on this shared server)" }
}

#--- Artifacts --------------------------------------------------------------

function Get-Artifact {
    # Return a local path for either a local path or a URL. Verifies sha256 when
    # one is given -- the update path (Phase 3) makes that mandatory; here it is
    # optional because the operator may be pointing at a file they just built.
    param([string]$Source, [string]$Sha256, [string]$Label)
    if (Test-Path $Source) {
        Write-Substep "$Label from local file: $Source"
        $local = $Source
    } else {
        $local = Join-Path $env:TEMP ([System.IO.Path]::GetFileName(([uri]$Source).LocalPath))
        if (Test-Path $local) {
            Write-Substep "$Label already downloaded: $local"
        } else {
            Write-Substep "$Label downloading: $Source"
            Invoke-WebRequest -Uri $Source -OutFile $local -UseBasicParsing
        }
    }
    if ($Sha256) {
        $actual = (Get-FileHash -Path $local -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Throw-Stop "$Label sha256 mismatch. Expected $Sha256, got $actual."
        }
        Write-Ok "$Label sha256 verified"
    }
    return $local
}

function Expand-Artifacts {
    Write-Step 'Unpacking binaries'

    # --- backend ---
    $zip = Get-Artifact -Source $AppZip -Sha256 $AppZipSha256 -Label 'Backend'
    $stage = Join-Path $env:TEMP ('3dx-app-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Expand-Archive -Path $zip -DestinationPath $stage -Force

    # Tolerate both shapes: files at the zip root, or nested in a single folder.
    $exe = Get-ChildItem -Path $stage -Filter 'BomExplorer.exe' -Recurse -File | Select-Object -First 1
    if (-not $exe) { Throw-Stop "BomExplorer.exe not found in $AppZip -- is this the native (self-contained) artifact?" }
    $appRoot = $exe.Directory.FullName

    # ADR-030 finding 1: wwwroot is NOT part of `dotnet publish`; the Dockerfile
    # injects it. If it is missing here, the artifact was built wrong and the
    # customer would get a working API with no UI -- fail now, loudly.
    if (-not (Test-Path (Join-Path $appRoot 'wwwroot\index.html'))) {
        Throw-Stop "The artifact has no wwwroot\index.html. The packaging job must run 'npm run build' and copy frontend/dist into the publish output."
    }

    $ver = (Get-Item $exe.FullName).VersionInfo.ProductVersion
    if (-not $ver) { $ver = '0.0.0' }
    $ver = ($ver -split '\+')[0]
    $Script:EffVersion = $ver
    $target = Join-Path $script:P.Versions $ver

    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    # ADR-030 consequence 4: never extract over a live directory. Stage first,
    # then move into place -- a half-extracted version directory is a state no
    # digest describes.
    New-Item -ItemType Directory -Path $script:P.Versions -Force | Out-Null
    Move-Item -Path $appRoot -Destination $target
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Backend $ver -> versions\$ver"

    # current\ -> versions\<v>. This junction is the native equivalent of an
    # image digest, and repointing it is the whole update/rollback mechanism.
    if (Test-Path $script:P.Current) { (Get-Item $script:P.Current).Delete() }
    New-Item -ItemType Junction -Path $script:P.Current -Target $target | Out-Null
    Write-Ok "current\ -> versions\$ver"

    # --- PostgreSQL ---
    if (-not (Test-Path (Join-Path $script:P.Pgsql 'bin\initdb.exe'))) {
        $pg = Get-Artifact -Source $PostgresZip -Label 'PostgreSQL'
        $pgStage = Join-Path $env:TEMP ('3dx-pg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $pg -DestinationPath $pgStage -Force
        $inner = Get-ChildItem -Path $pgStage -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'bin\initdb.exe') } | Select-Object -First 1
        if (-not $inner) { Throw-Stop "initdb.exe not found in $PostgresZip" }
        if (Test-Path $script:P.Pgsql) { Remove-Item $script:P.Pgsql -Recurse -Force }
        Move-Item -Path $inner.FullName -Destination $script:P.Pgsql
        Remove-Item $pgStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:__out = @()
    [void](Invoke-Native -FilePath (Join-Path $script:P.Pgsql 'bin\postgres.exe') -Arguments @('--version') `
        -OnOutput { param($l) $script:__out += $l })
    Write-Ok "PostgreSQL: $($script:__out -join ' ')"

    # --- Caddy ---
    if (-not (Test-Path $script:P.CaddyExe)) {
        $cz = Get-Artifact -Source $CaddyZip -Label 'Caddy'
        $cStage = Join-Path $env:TEMP ('3dx-caddy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-Archive -Path $cz -DestinationPath $cStage -Force
        $cexe = Get-ChildItem -Path $cStage -Filter 'caddy.exe' -Recurse -File | Select-Object -First 1
        if (-not $cexe) { Throw-Stop "caddy.exe not found in $CaddyZip" }
        New-Item -ItemType Directory -Path $script:P.CaddyDir -Force | Out-Null
        Move-Item -Path $cexe.FullName -Destination $script:P.CaddyExe
        Remove-Item $cStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:__out = @()
    [void](Invoke-Native -FilePath $script:P.CaddyExe -Arguments @('version') `
        -OnOutput { param($l) $script:__out += $l })
    Write-Ok "Caddy: $($script:__out | Select-Object -First 1)"
}

#--- Database ---------------------------------------------------------------

function Install-Database {
    $bin = Join-Path $script:P.Pgsql 'bin'

    # REINSTALLING OVER KEPT DATA IS A SUPPORTED PATH, so it has to work.
    # uninstall-native.ps1 keeps DataDir by default and says, in its own output,
    # that a re-install reuses the seed -- and the install guide tells customers
    # the same thing. Before this, the second install died on
    # `initdb: directory exists but is not empty`, leaving the gateway removed
    # and un-reinstallable except by deleting the database. The promise was in
    # three places and true in none. (ADR-030 Phase 4 gate, T4.)
    if (Test-Path (Join-Path $script:P.PgData 'PG_VERSION')) {
        Install-DatabaseReusingCluster -Bin $bin
        return
    }

    Write-Step "Creating the PostgreSQL cluster (locale $DbLocale, scram-sha-256)"
    $Script:DbPassword = New-RandomHex -Bytes 16

    $pwFile = Join-Path $env:TEMP ('3dx-pgpw-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        Set-Content -Path $pwFile -Value $Script:DbPassword -NoNewline -Encoding ascii
        New-Item -ItemType Directory -Path (Split-Path $script:P.PgData -Parent) -Force | Out-Null

        # ADR-030 finding 2: initdb defaults local connections to `trust`. On a
        # shared server that means any local process reaches the database with
        # no password. -A scram-sha-256 is mandatory, not a preference.
        # finding 3: the locale is fixed here forever -- see -DbLocale. Windows
        # PG16 accepts the glibc-style name (probed, not assumed).
        $script:__out = @()
        $code = Invoke-Native -FilePath (Join-Path $bin 'initdb.exe') -Arguments @(
            '-D', $script:P.PgData, '-U', $DB_USER, '-A', 'scram-sha-256',
            "--pwfile=$pwFile", '-E', 'UTF8', "--locale=$DbLocale"
        ) -OnOutput { param($l) $script:__out += $l }
        if ($code -ne 0) { $script:__out | ForEach-Object { Write-Substep $_ }; Throw-Stop 'initdb failed.' }
    } finally {
        # The password file is deleted whatever happens; it is plaintext.
        Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Cluster created at $($script:P.PgData)"

    Set-PgConfBlock
    Register-PgService -Bin $bin
    Initialize-GatewayDatabase -Bin $bin
}

function Install-DatabaseReusingCluster {
    param([string]$Bin)
    Write-Step "Reusing the PostgreSQL cluster already in $($script:P.PgData)"

    # The cluster's password exists in exactly one place we can still read: the
    # .env kept alongside it. It cannot be regenerated -- it is baked into the
    # cluster's own authentication -- so a data directory without its .env is a
    # database nobody can open. Say that plainly instead of failing later with a
    # password-authentication error that reads like a bug.
    $Script:DbPassword = Get-EnvFileValue -Path $script:P.Env -Key 'POSTGRES_PASSWORD'
    if (-not $Script:DbPassword) {
        Throw-Stop @"
$($script:P.PgData) holds an existing database, but $($script:P.Env) has no POSTGRES_PASSWORD.
The password is stored nowhere else and cannot be recreated, so this cluster cannot be opened.
Either restore the .env that belongs to this data directory, or delete
  $($script:P.PgData)
to start with an empty database (THIS DESTROYS THE EXISTING DATA).
"@
    }
    Write-Ok 'Database password recovered from .env'
    Write-Substep 'The existing schema and data are left exactly as they are; EF migrations run at first start.'

    Set-PgConfBlock
    Register-PgService -Bin $Bin
    Initialize-GatewayDatabase -Bin $Bin
}

function Set-PgConfBlock {
    # Loopback only. On a shared server the database must not be reachable from
    # the network even if a firewall rule is later added by someone else.
    #
    # REPLACE the block rather than appending: on a reinstall the file already
    # carries one, and a second `port =` would leave two answers to the same
    # question in a file an operator is expected to be able to read.
    $conf = Join-Path $script:P.PgData 'postgresql.conf'
    $marker = '# --- 3DX Gateway (install-native.ps1) ---'
    $block = @"
$marker
listen_addresses = '127.0.0.1'
port = $($Script:EffPgPort)
"@
    if (Test-Path $conf) {
        $text = Get-Content $conf -Raw
        if ($text -match [regex]::Escape($marker)) {
            # Stop at a blank line, the next comment, or end of file. Our block
            # contains neither, and this is somebody's postgresql.conf: a
            # greedier pattern would silently eat a setting an operator added
            # after ours, which is a far worse outcome than a duplicate line.
            $text = [regex]::Replace($text,
                "(?s)\r?\n?$([regex]::Escape($marker)).*?(?=\r?\n\s*\r?\n|\r?\n#|\z)", '')
        }
        Set-Content -Path $conf -Value ($text.TrimEnd("`r", "`n") + "`r`n`r`n" + $block) -Encoding UTF8
    }
}

function Register-PgService {
    param([string]$Bin)
    # pg_ctl register creates a proper Windows service; no MSI, nothing
    # machine-wide, and the version stays pinned to the binaries we unpacked.
    $code = Invoke-Native -FilePath (Join-Path $Bin 'pg_ctl.exe') `
        -Arguments @('register', '-N', $SVC_DB, '-D', $script:P.PgData, '-S', 'auto') `
        -OnOutput { param($l) Write-Substep $l }
    if ($code -ne 0) { Throw-Stop "pg_ctl register failed for $SVC_DB." }
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('failure', $SVC_DB, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/30000'))
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('description', $SVC_DB, '3DX Gateway database (PostgreSQL 16, loopback only).'))

    Start-Service $SVC_DB
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 2
        $ready = (Invoke-Native -FilePath (Join-Path $Bin 'pg_isready.exe') `
            -Arguments @('-h', '127.0.0.1', '-p', "$($Script:EffPgPort)", '-q')) -eq 0
    } while (-not $ready -and (Get-Date) -lt $deadline)
    if (-not $ready) { Throw-Stop "$SVC_DB did not become ready. See $($script:P.PgData)\log." }
    Write-Ok "$SVC_DB running on 127.0.0.1:$($Script:EffPgPort)"
}

function Initialize-GatewayDatabase {
    param([string]$Bin)
    $env:PGPASSWORD = $Script:DbPassword
    try {
        # Ask whether the database is there rather than creating it and reading
        # the failure. `createdb` fails the same way for "it already exists" and
        # for "your password is wrong", and treating the second as the first is
        # how a broken install gets reported as a successful one.
        $script:__out = @()
        $code = Invoke-Native -FilePath (Join-Path $Bin 'psql.exe') -Arguments @(
            '-h', '127.0.0.1', '-p', "$($Script:EffPgPort)", '-U', $DB_USER, '-d', 'postgres', '-At',
            '-c', "select 1 from pg_database where datname='$DB_NAME'"
        ) -OnOutput { param($l) $script:__out += $l }
        if ($code -ne 0) {
            $script:__out | ForEach-Object { Write-Substep $_ }
            Throw-Stop "Could not query the database server as '$DB_USER'. If this is an existing cluster, the password in .env does not match it."
        }
        $exists = (($script:__out -join '').Trim() -eq '1')

        if (-not $exists) {
            $script:__out = @()
            $code = Invoke-Native -FilePath (Join-Path $Bin 'createdb.exe') `
                -Arguments @('-h', '127.0.0.1', '-p', "$($Script:EffPgPort)", '-U', $DB_USER, $DB_NAME) `
                -OnOutput { param($l) $script:__out += $l }
            if ($code -ne 0) { $script:__out | ForEach-Object { Write-Substep $_ }; Throw-Stop "Could not create database $DB_NAME." }
        }

        # Report what the cluster ACTUALLY got, in the same form the Linux side
        # answers, so an operator can compare the two directly instead of
        # trusting that initdb honoured the request. The collation cannot be
        # changed later without recreating the cluster, so this is the last
        # cheap moment to notice a mismatch.
        $script:__out = @()
        [void](Invoke-Native -FilePath (Join-Path $Bin 'psql.exe') -Arguments @(
            '-h', '127.0.0.1', '-p', "$($Script:EffPgPort)", '-U', $DB_USER, '-d', $DB_NAME, '-At',
            '-c', "select datcollate||' '||datctype from pg_database where datname=current_database()"
        ) -OnOutput { param($l) $script:__out += $l })
        $actual = ($script:__out -join ' ').Trim()
        Write-Ok "Database $DB_NAME $(if ($exists) { 'reused' } else { 'created' }) -- collation: $actual"
        Write-Substep "Compare with the source cluster before any migration:"
        Write-Substep "  psql -Atc `"select datcollate||' '||datctype from pg_database where datname=current_database()`""
    } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
    Write-Substep 'Schema is applied by the backend at first start (EF migrations).'
}

#--- Configuration ----------------------------------------------------------

function Write-Configuration {
    Write-Step 'Writing configuration'

    # Preserve an existing seed if one is somehow already here: without the
    # original seed every ENC: value in appsettings.json decrypts to an empty
    # string, silently, and the customer re-types every credential.
    $Script:Seed = Get-EnvFileValue -Path $script:P.Env -Key 'CONFIG_PROTECTOR_SEED'
    if (-not $Script:Seed) { $Script:Seed = New-RandomHex -Bytes 32 }

    $envText = @"
# 3DX Gateway (native) -- generated $(Get-Date -Format 'o') by install-native.ps1 v$INSTALLER_VERSION.
# SENSITIVE. This file and appsettings.json must always travel TOGETHER: without
# CONFIG_PROTECTOR_SEED every ENC: value in appsettings.json fails silently.
POSTGRES_PASSWORD=$($Script:DbPassword)
CONFIG_PROTECTOR_SEED=$($Script:Seed)
HOSTNAME=$($Script:EffHostName)
APP_PORT=$($Script:EffPort)
HTTP_PORT=$($Script:EffHttpPort)
BACKEND_PORT=$($Script:EffAppPort)
PG_PORT=$($Script:EffPgPort)
TLS_MODE=$Tls
TELEMETRY=$Telemetry
"@
    Set-Content -Path $script:P.Env -Value $envText -Encoding UTF8
    Protect-SecretFile -Path $script:P.Env
    Write-Ok ".env written and locked to SYSTEM + Administrators"

    # appsettings.json. The canonical copy lives in DataDir and is COPIED into
    # the version directory, because the backend reads AND WRITES it at its
    # content root (IntegrationController.cs:1631 -- the Settings UI persists
    # Pantheon credentials, field mappings and webhooks there).
    #
    # ADR-030 finding 10, and Phase 3 MUST honour it: repointing the junction to
    # a new version directory would otherwise revert every customer setting to
    # factory defaults, silently. The update worker has to carry the live
    # appsettings.json forward into the new version directory before starting
    # the service, and copy it back here.
    $versionSettings = Join-Path $script:P.Current 'appsettings.json'
    if (-not (Test-Path $script:P.AppSettings)) {
        if (Test-Path $versionSettings) {
            Copy-Item $versionSettings $script:P.AppSettings
        } else {
            Set-Content -Path $script:P.AppSettings -Value '{}' -Encoding UTF8
        }
    }
    # The connection string is config, not an environment secret, so it lives
    # with the rest of the settings the operator may need to inspect.
    $json = Get-Content $script:P.AppSettings -Raw | ConvertFrom-Json
    if (-not $json.ConnectionStrings) {
        $json | Add-Member -NotePropertyName ConnectionStrings -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $json.ConnectionStrings | Add-Member -NotePropertyName BomExplorer `
        -NotePropertyValue "Host=127.0.0.1;Port=$($Script:EffPgPort);Database=$DB_NAME;Username=$DB_USER;Password=$($Script:DbPassword)" -Force
    $json | ConvertTo-Json -Depth 32 | Set-Content -Path $script:P.AppSettings -Encoding UTF8
    Protect-SecretFile -Path $script:P.AppSettings
    Copy-Item $script:P.AppSettings $versionSettings -Force
    Write-Ok "appsettings.json written, locked, and seeded into versions\$($Script:EffVersion)"

    if ($License -and (Test-Path $License)) {
        Copy-Item $License $script:P.License -Force
        Copy-Item $script:P.License (Join-Path $script:P.Current 'license.lic') -Force
        Write-Ok 'license.lic installed'
    }

    # The update worker (ADR-030 Phase 3). It SHIPS INSIDE the artifact
    # (host\apply-worker-native.ps1) so its version tracks the backend's, and it
    # is copied to a stable path in DataDir because that is what the service's
    # Updates__WorkerScript points at -- a path inside versions\<v>\ would move
    # under the running backend on every update. The backend re-syncs this copy
    # from the active version on its own, so a later upgrade also upgrades the
    # worker without anyone remembering to.
    $workerSrc = Join-Path $script:P.Current 'host\apply-worker-native.ps1'
    if (Test-Path $workerSrc) {
        $workerDst = Join-Path $DataDir 'apply-worker-native.ps1'
        Copy-Item $workerSrc $workerDst -Force
        # Locked like a secret, though it holds none: this script is executed as
        # LocalSystem, so write access to it is write access to the machine, and
        # the server is shared with other applications and their users.
        Protect-SecretFile -Path $workerDst
        Write-Ok 'Update worker installed and locked (one-click Apply Update is available)'
    } else {
        Write-Warn2 'The artifact carries no host\apply-worker-native.ps1 -- one-click Apply Update will report itself unavailable until a newer artifact is installed.'
    }

    $caddyfile = New-CaddyfileText `
        -HostName $Script:EffHostName -Port $Script:EffPort -HttpPort $Script:EffHttpPort `
        -Tls $Tls -Upstream "127.0.0.1:$($Script:EffAppPort)" -CaddyDataRoot $script:P.CaddyData `
        -EmitSitePorts -DisableAdminApi -EmitStorage
    Set-Content -Path $script:P.Caddyfile -Value $caddyfile -Encoding UTF8
    Write-Ok 'Caddyfile written'
}

#--- Services ---------------------------------------------------------------

function Protect-ServiceKey {
    # Restrict a service's registry key to SYSTEM + Administrators. Needed
    # because the key's Environment value carries ConfigProtector__Seed, and the
    # default ACL on HKLM\SYSTEM\CurrentControlSet\Services\<name> grants read
    # access to ordinary local users -- who exist in numbers on a shared server.
    param([string]$ServiceName)
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $acl = Get-Acl -Path $path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $account = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
            $account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -Path $path -AclObject $acl

    # Read it back. An ACL that silently failed to apply is worse than none,
    # because the seed is sitting there either way.
    $check = (Get-Acl -Path $path).Access |
             Where-Object { $_.IdentityReference -notmatch 'SYSTEM|Administrators' }
    if ($check) {
        Throw-Stop "Could not lock $path -- these identities still have access: $(($check.IdentityReference | Select-Object -Unique) -join ', ')"
    }
    Write-Ok "Service key locked to SYSTEM + Administrators (it holds the ConfigProtector seed)"
}

function Install-BackendService {
    Write-Step "Registering $SVC_APP"

    $exe = Join-Path $script:P.Current 'BomExplorer.exe'
    $code = Invoke-Native -FilePath 'sc.exe' -Arguments @('create', $SVC_APP, 'binPath=', "`"$exe`"", 'start=', 'auto', 'DisplayName=', '3DX Gateway') `
        -OnOutput { param($l) Write-Substep $l }
    if ($code -ne 0) { Throw-Stop "Could not create service $SVC_APP." }
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('description', $SVC_APP, '3DX Gateway backend (ASP.NET Core, loopback only; fronted by 3DXGatewayProxy).'))
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('failure', $SVC_APP, 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/30000'))

    # The backend runs EF migrations at startup (Program.cs), so it needs the
    # database to be accepting connections before it starts. Without this the SCM
    # starts both in parallel after a reboot and the backend loses the race: it
    # throws, dies, and only comes back via the recovery actions ~5 s later.
    # It would look self-healing and be, in effect, a crash on every boot -- and
    # "it recovers" is not the same as "it starts". The recovery actions stay as
    # the backstop for the case where Postgres is up but not yet ready.
    [void](Invoke-Native -FilePath 'sc.exe' -Arguments @('config', $SVC_APP, 'depend=', $SVC_DB))

    # ADR-030 finding 8: a service inherits NOTHING from the shell environment,
    # and the whole configuration surface is `__` env vars. They go in the
    # service key's Environment value.
    #
    # ConfigProtector__Seed HAS to be here, and that is not a preference.
    # ConfigProtector.DeriveKey() (ConfigProtector.cs:73) reads the environment
    # variable ONLY -- it never consults IConfiguration -- and its fallback is
    #     MachineName | AppContext.BaseDirectory | BomExplorer
    # whose BaseDirectory under this layout is versions\<v>\. That changes with
    # every update, so an unset seed would silently invalidate every ENC: value
    # in appsettings.json on the first upgrade: Pantheon credentials, field
    # mappings, webhooks. The customer would just see integrations stop working.
    # (ADR-030 finding 11.)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$SVC_APP"
    Set-ItemProperty -Path $key -Name Environment -Type MultiString -Value @(
        "ASPNETCORE_ENVIRONMENT=Production",
        "ASPNETCORE_URLS=http://127.0.0.1:$($Script:EffAppPort)",
        "BACKEND_LOG_DIR=$($script:P.Logs)",
        "Staging__Root=$(Join-Path $script:P.AppData 'staging')",
        "CadBridgeInstaller__CacheDirectory=$(Join-Path $script:P.AppData 'cadbridge-cache')",
        # ADR-030 finding 9. The backend's own default is now OS-aware, but
        # appsettings.json SHIPS "Updates:HelperEndpoint": "unix:/var/run/..."
        # -- a configured value beats a default, so the Linux socket path would
        # win here and one-click Apply would report itself permanently
        # unavailable, quietly. The env var beats appsettings.json, which is why
        # it is set explicitly rather than left to the default.
        "Updates__HostKind=windows",
        # Phase 3: no helper process on this path. The backend is a service
        # running as LocalSystem, so it forks apply-worker-native.ps1 itself.
        "Updates__HelperEndpoint=local",
        "Updates__Channel=native",
        "Updates__StateDir=$DataDir",
        "Updates__InstallDir=$InstallDir",
        "Updates__ServiceName=$SVC_APP",
        "Telemetry__Enabled=$([string]($Telemetry -eq 'on'))",
        "ConfigProtector__Seed=$($Script:Seed)"
    )
    # ...which puts a secret in the registry, and service keys are READABLE BY
    # ORDINARY USERS by default. On a shared server that is unacceptable, so the
    # key's ACL is tightened to SYSTEM + Administrators before the service ever
    # starts. Verified by re-reading the ACL below rather than assumed.
    Protect-ServiceKey -ServiceName $SVC_APP

    Start-Service $SVC_APP
    Write-Ok "$SVC_APP started (migrations run at first start)"
}

function Install-ProxyService {
    # caddy.exe does not implement the Windows service control protocol -- a
    # bare `sc create` + `sc start` fails with 1053 ("did not respond in a
    # timely fashion") even though the process itself is healthy.
    # caddyserver.com/docs/running documents WinSW as the wrapper, and
    # caddyserver/caddy#4670 (a native service stub) is still open. So the proxy
    # is a real Automatic service with real recovery actions -- via WinSW.
    #
    # WinSW's convention: the wrapper executable and its XML share a base name,
    # and that name is the service id.
    Write-Step "Registering $SVC_PROXY (Caddy via WinSW)"
    New-Item -ItemType Directory -Path $script:P.CaddyData -Force | Out-Null

    $wrapper = Join-Path $script:P.CaddyDir "$SVC_PROXY.exe"
    if (-not (Test-Path $wrapper)) {
        $w = Get-Artifact -Source $WinSwExe -Sha256 $WINSW_SHA256 -Label 'WinSW'
        Copy-Item $w $wrapper -Force
    }

    # WinSW reads the XML in the wrapper's own directory. Paths are absolute:
    # the service starts with CurrentDirectory = C:\Windows\system32, the same
    # trap the backend had (ADR-030 Phase 1).
    #
    # KEEP THE RATIONALE OUT OF THE XML. Long explanations belong here, in
    # PowerShell comments, not in <!-- --> blocks: an XML comment may not
    # contain a double hyphen, so an ordinary English aside written with one
    # makes WinSW refuse the whole configuration and the proxy never registers.
    # That is not hypothetical -- it is how the Phase 4 gate opened, on a
    # comment added the same morning. The XML carries values; this carries why.
    #
    # WHY XDG_DATA_HOME AND NOT SOMETHING ELSE:
    # Caddy keeps its certificates and the local CA under this directory, which
    # lives in ProgramData and NOT in the versioned install tree -- an update
    # must never regenerate the CA, because every workstation has imported it
    # (ADR-029 data rule, carried into ADR-030).
    #
    # The AUTHORITATIVE declaration is `storage file_system` in the Caddyfile,
    # right next to the handler that serves root.crt, so the two cannot drift.
    # XDG_DATA_HOME is set as well only so that caddy.exe run BY HAND for
    # diagnostics touches the same tree, instead of quietly creating a second
    # local CA in the invoking user's profile: two roots with the same CN on one
    # network is a failure we have already paid for once.
    #
    # NOTE THE SHAPE: Caddy APPENDS "caddy" to XDG_DATA_HOME, so the value must
    # be the PARENT of the caddy data directory, not the directory itself.
    #
    # An earlier version set CADDY_DATA_DIR, a variable Caddy does not read at
    # all. It cost nothing to write and produced a live 404 on /caddy-ca.crt
    # that survived two phase gates (finding 13).
    $xml = @"
<service>
  <id>$SVC_PROXY</id>
  <name>3DX Gateway Proxy</name>
  <description>3DX Gateway TLS reverse proxy (Caddy). Terminates TLS on :$($Script:EffPort) and forwards to the backend on loopback.</description>
  <executable>$($script:P.CaddyExe)</executable>
  <arguments>run --config "$($script:P.Caddyfile)" --adapter caddyfile</arguments>
  <workingdirectory>$($script:P.CaddyDir)</workingdirectory>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 day</resetfailure>
  <logpath>$($script:P.Logs)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
  <!-- Caddy data directory. See the PowerShell comment above for why. -->
  <env name="XDG_DATA_HOME" value="$(Split-Path -Parent $script:P.CaddyData)"/>
  <env name="HOME" value="$DataDir"/>
  <stoptimeout>20 sec</stoptimeout>
</service>
"@
    # Parse it before writing it. WinSW's own failure for malformed XML is a
    # stack trace ending in "The configuration file cound not be loaded" [sic],
    # by which point the backend and the database are already registered and the
    # operator has a half-installed gateway. One cast turns that into a clear
    # message before anything is touched.
    try { [void][xml]$xml } catch {
        Throw-Stop "Generated an invalid $SVC_PROXY.xml: $($_.Exception.Message). This is a bug in the installer, not in your configuration."
    }
    Set-Content -Path (Join-Path $script:P.CaddyDir "$SVC_PROXY.xml") -Value $xml -Encoding UTF8

    $code = Invoke-Native -FilePath $wrapper -Arguments @('install') -OnOutput { param($l) Write-Substep $l }
    if ($code -ne 0) { Throw-Stop "WinSW could not register $SVC_PROXY." }

    Start-Service $SVC_PROXY
    $svc = Get-Service $SVC_PROXY
    if ($svc.Status -ne 'Running') { Throw-Stop "$SVC_PROXY did not reach Running (status $($svc.Status))." }
    Write-Ok "$SVC_PROXY running (TLS on :$($Script:EffPort))"
}

function Set-FirewallRulesNative {
    if ($SkipFirewall) { Write-Substep 'Firewall rules skipped (-SkipFirewall)'; return }
    Write-Step 'Firewall'
    foreach ($p in @($Script:EffPort, $Script:EffHttpPort)) {
        if ($p -eq 0) { continue }
        $name = "3DX Gateway TCP $p"
        if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow | Out-Null
        }
        Write-Ok "Inbound TCP $p allowed"
    }
    Write-Substep 'Backend and PostgreSQL are loopback-only; no rule is added for them.'
}

#--- Smoke ------------------------------------------------------------------

function Invoke-SmokeTest {
    Write-Step 'Smoke test'
    $direct = "http://127.0.0.1:$($Script:EffAppPort)/api/version"
    $ok = $false
    foreach ($i in 1..30) {
        Start-Sleep -Seconds 2
        try { $v = Invoke-RestMethod $direct -TimeoutSec 5; if ($v.backend.current) { $ok = $true; break } } catch { }
    }
    if ($ok) { Write-Ok "Backend answers: $($v.backend.current)" }
    else { Write-Fail "Backend did not answer on $direct -- see $($script:P.Logs)"; return $false }

    $through = "https://$($Script:EffHostName):$($Script:EffPort)/api/version"
    try {
        # The local CA is not trusted on the server itself yet; skip validation
        # here. Certificate trust is a workstation concern (/caddy-ca.crt).
        $r = Invoke-RestInsecure -Uri $through -TimeoutSec 10
        Write-Ok "Through Caddy: $($r.backend.current)"
    } catch {
        Write-Fail "Not reachable through Caddy at $through -- $($_.Exception.Message)"
        return $false
    }

    # The CA download. This is not decoration: until /caddy-ca.crt serves a real
    # certificate, NO workstation can install CadBridge -- Setup.ps1's whole
    # bootstrap is fetching this file. The gateway itself looks perfectly healthy
    # meanwhile, which is how a 404 here survived two phase gates: Caddy stored
    # its CA under the service account's %AppData% while the handler served an
    # empty ProgramData directory (fixed 2026-08-14 via `storage file_system`).
    #
    # Parse it as X.509 rather than trusting a 200: an HTTP site that answers
    # with somebody's error page is still a 200, and a 0-byte body is still a
    # successful download.
    $caUrl = if ($Script:EffHttpPort -ne 0) {
        "http://$($Script:EffHostName):$($Script:EffHttpPort)/caddy-ca.crt"
    } else {
        "https://$($Script:EffHostName):$($Script:EffPort)/caddy-ca.crt"
    }
    $caTmp = Join-Path $env:TEMP ("3dx-ca-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".crt")
    try {
        $code = Invoke-Native -FilePath 'curl.exe' `
            -Arguments @('-k', '-fsS', '--connect-timeout', '5', '--max-time', '20', '-o', $caTmp, $caUrl)
        if ($code -ne 0) { throw "curl exit $code" }
        $caCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($caTmp)
        Write-Ok "CA downloadable: $($caCert.Subject) (expires $($caCert.NotAfter.ToString('yyyy-MM-dd')))"
    } catch {
        Write-Fail "The local CA is NOT downloadable at $caUrl -- $($_.Exception.Message)"
        Write-Substep 'Workstations cannot install CadBridge until this serves a certificate.'
        Write-Substep 'Check that the Caddyfile storage file_system path and the /caddy-ca.crt handler root agree.'
        return $false
    } finally {
        Remove-Item $caTmp -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Show-Summary {
    Write-Hr
    Write-Host ''
    Write-Host "3DX Gateway installed." -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL             https://$($Script:EffHostName):$($Script:EffPort)"
    if ($Script:EffHttpPort -ne 0) {
        Write-Host "  CA for clients  http://$($Script:EffHostName):$($Script:EffHttpPort)/caddy-ca.crt"
    }
    Write-Host "  Services        $SVC_APP, $SVC_DB, $SVC_PROXY  (all Automatic, all session 0)"
    Write-Host "  Version         $($Script:EffVersion)  (current\ -> versions\$($Script:EffVersion))"
    Write-Host "  Data            $DataDir"
    Write-Host "  Logs            $($script:P.Logs)"
    Write-Host ''
    Write-Warn2 "Back up $($script:P.Env) and $($script:P.AppSettings) TOGETHER. Without the seed, every stored credential is unrecoverable."
    Write-Host ''
}

#--- Main -------------------------------------------------------------------

Show-Banner
Initialize-Paths
Test-Preflight
Resolve-Config

if ($DryRun) {
    Write-Host ''
    Write-Warn2 'DryRun: configuration resolved, nothing installed.'
    Write-Host "  hostname=$($Script:EffHostName) https=$($Script:EffPort) http=$($Script:EffHttpPort) backend=$($Script:EffAppPort) pg=$($Script:EffPgPort) locale=$DbLocale"
    return
}

foreach ($d in @($InstallDir, $DataDir, $script:P.Versions, $script:P.Logs, $script:P.AppData, $script:P.CaddyData)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

Expand-Artifacts
Install-Database
Write-Configuration
Install-BackendService
Install-ProxyService
Set-FirewallRulesNative
$smoke = Invoke-SmokeTest
Show-Summary
if (-not $smoke) { exit 1 }
