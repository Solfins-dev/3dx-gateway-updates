<#
.SYNOPSIS
3DX Gateway -- Windows Server installer (ADR-015 Phase B initial setup).

.DESCRIPTION
PowerShell mirror of scripts/install.sh. Same UX, same compose file layout,
same Caddy local-CA TLS story; Windows-specific idioms throughout.

The script is ASCII-only by hard rule (PS 5.1 misparses non-ASCII bytes
depending on the host codepage -- see reference_powershell_5_1_ascii_only).
Em-dashes, smart quotes, accents are forbidden.

Differences vs install.sh:
  - No systemd. Customer relies on Docker Desktop's autostart OR adds the
    compose `up -d` command to Task Scheduler / a Windows Service. The
    container `restart: unless-stopped` setting handles in-session restart.
  - No Apply Update host helper installation -- the Phase 2(a) helper is
    systemd-socket based and has no Windows port yet. The web UI's Settings
    Apply Update card falls back to its copy-SSH-command UX for Windows
    hosts.
  - Port check via Get-NetTCPConnection instead of ss.
  - Docker auto-install is unsupported; if Docker is missing we print a
    pointer to docker.com/products/docker-desktop and exit.
  - Admin-elevation via self-restart with -Verb RunAs.

.PARAMETER InstallDir
Install location. Default: C:\ProgramData\3DX-Gateway

.PARAMETER Hostname
Gateway FQDN workstations will use. Default: auto-detect via [System.Net.Dns]::GetHostEntry.

.PARAMETER Port
HTTPS port (default 443) or HTTP if -Tls none (default 5000).

.PARAMETER Tls
TLS mode: auto | letsencrypt | none. Default: auto.
  auto:        Caddy with local CA (recommended for LAN)
  letsencrypt: Caddy with Let's Encrypt (public hostname required)
  none:        plain HTTP (you provide reverse proxy)

.PARAMETER License
Path to license.lic from Solfins. Required.

.PARAMETER Telemetry
on | off. ADR-015 7.5 anonymous hourly ping. Default: on.

.PARAMETER Yes
Unattended: skip all confirmation prompts and use defaults for unanswered.

.PARAMETER DryRun
Show what would happen, don't make changes.

.EXAMPLE
PS> iwr -useb https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main/install.ps1 -OutFile $env:TEMP\install.ps1
PS> & $env:TEMP\install.ps1

.EXAMPLE
# Unattended
PS> & $env:TEMP\install.ps1 -Hostname gateway.acme.local -License C:\tmp\acme.lic -Yes

.LINK
https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/INSTALL.md
#>

[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$Hostname,
    [int]$Port,
    [ValidateSet('auto', 'letsencrypt', 'none')]
    [string]$Tls,
    [string]$License,
    [ValidateSet('on', 'off')]
    [string]$Telemetry,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Constants
$INSTALLER_VERSION   = '1.0.0'
$PUBLIC_REPO_BASE    = 'https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main'
$GHCR_IMAGE          = 'ghcr.io/solfins-dev/3dx-gateway:latest'
$DEFAULT_INSTALL_DIR = 'C:\ProgramData\3DX-Gateway'
$DEFAULT_PORT_TLS    = 443
$DEFAULT_PORT_HTTP   = 5000
$MIN_DISK_GB         = 5
$MIN_RAM_MB          = 1800

# Effective values (filled by Resolve-Config from params + prompts)
$Script:EffInstallDir       = $null
$Script:EffHostname         = $null
$Script:EffPort             = $null
$Script:EffTls              = $null
$Script:EffLicense          = $null
$Script:EffTelemetry        = $null
$Script:EffPostgresPassword = $null

#--- Output helpers ---------------------------------------------------------

function Write-Step    { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Substep { param([string]$Text) Write-Host "    $Text" }
function Write-Ok      { param([string]$Text) Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn2   { param([string]$Text) Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Text) Write-Host "    [X]  $Text" -ForegroundColor Red }
function Throw-Stop    { param([string]$Text) Write-Fail $Text; throw $Text }
function Write-Hr      { Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray }

function Show-Banner {
    Write-Host ''
    Write-Host "3DX Gateway Installer v$INSTALLER_VERSION (Windows)" -ForegroundColor Cyan
    Write-Host "One-shot setup. Solfins-dev/3dx-gateway-updates." -ForegroundColor DarkGray
    Write-Host ''
}

#--- Pre-flight -------------------------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-IsAdmin)) {
        Throw-Stop "Re-run this script from an elevated PowerShell (Run as Administrator). The installer needs Admin to write to C:\ProgramData and bind privileged ports."
    }
}

function Test-OS {
    Write-Step "Checking OS"
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption
    $build   = [int]($os.BuildNumber)
    # Windows Server 2019 = build 17763; Server 2022 = 20348; Win 10 21H2 = 19044
    if ($build -lt 17763) {
        Throw-Stop "Unsupported OS: $caption (build $build). Need Windows Server 2019+ or Windows 10 21H2+."
    }
    Write-Ok "$caption (build $build)"
}

function Test-Docker {
    Write-Step "Checking Docker"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warn2 "Docker not installed."
        Write-Substep "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
        Write-Substep "(Auto-install on Windows is not supported by this installer -- the MSI is interactive.)"
        Throw-Stop "Install Docker Desktop, ensure it's running, then re-run this script."
    }
    try {
        $null = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            Throw-Stop "Docker daemon is not running. Start Docker Desktop and re-run."
        }
    } catch {
        Throw-Stop "Docker daemon is not running: $($_.Exception.Message)"
    }
    $v = (docker version --format '{{.Server.Version}}' 2>$null)
    Write-Ok "Docker $v (daemon running)"

    # docker compose v2 plugin
    try {
        $cv = (docker compose version --short 2>$null)
        if ([string]::IsNullOrWhiteSpace($cv)) {
            Throw-Stop "docker compose v2 plugin missing. Update Docker Desktop or install docker-compose-plugin."
        }
        Write-Ok "docker compose v$cv"
    } catch {
        Throw-Stop "docker compose v2 plugin missing: $($_.Exception.Message)"
    }
}

function Test-Disk {
    Write-Step "Checking free disk"
    $target = if ($InstallDir) { $InstallDir } else { $DEFAULT_INSTALL_DIR }
    $drive = (Split-Path -Qualifier $target).TrimEnd(':')
    $info = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
    if (-not $info) {
        Throw-Stop "Cannot find drive $drive (resolved from $target)."
    }
    $freeGb = [math]::Floor($info.Free / 1GB)
    if ($freeGb -lt $MIN_DISK_GB) {
        Throw-Stop "Only $freeGb GB free on drive $drive`:; need $MIN_DISK_GB GB minimum."
    }
    Write-Ok "$freeGb GB free on $drive`:"
}

function Test-Ram {
    Write-Step "Checking RAM"
    $cs = Get-CimInstance Win32_ComputerSystem
    $ramMb = [math]::Floor($cs.TotalPhysicalMemory / 1MB)
    if ($ramMb -lt $MIN_RAM_MB) {
        Write-Warn2 "$ramMb MB RAM; recommend at least 2048 MB. Postgres + app may swap under load."
    } else {
        Write-Ok "$ramMb MB RAM"
    }
}

function Test-PortFree {
    param([int]$P)
    $conn = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    return ($null -eq $conn -or $conn.Count -eq 0)
}

#--- Interactive prompts ----------------------------------------------------

# Returns 'y' or 'n'. In -Yes mode returns the default.
function Read-YesNo {
    param([string]$Question, [string]$Default = 'y')
    if ($Yes.IsPresent) { return $Default }
    $hint = if ($Default -eq 'n') { '[y/N]' } else { '[Y/n]' }
    $answer = Read-Host "    $Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    if ($answer -match '^(y|yes)$') { return 'y' } else { return 'n' }
}

function Read-TextPrompt {
    param([string]$Question, [string]$Default = '')
    if ($Yes.IsPresent) { return $Default }
    $hint = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "    $Question$hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function Resolve-InstallDir {
    Write-Step "Install location"
    $Script:EffInstallDir = if ($InstallDir) { $InstallDir } else {
        Read-TextPrompt "Install directory" $DEFAULT_INSTALL_DIR
    }
    if (Test-Path (Join-Path $Script:EffInstallDir 'docker-compose.yml')) {
        Throw-Stop "An install already exists at $($Script:EffInstallDir) (docker-compose.yml present). Remove it first or pick a different -InstallDir."
    }
    Write-Ok "Will install to: $($Script:EffInstallDir)"
}

function Get-DetectedFqdn {
    # Best-effort FQDN detection. GetHostByName / GetHostEntry can return the
    # bare short name on hosts without proper DNS/hosts entries. Try several
    # sources before falling back.

    # 1) [System.Net.Dns]::GetHostEntry of COMPUTERNAME -- usually returns FQDN
    try {
        $h = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
        if ($h -and $h.Contains('.')) { return $h }
    } catch { }

    # 2) Combine COMPUTERNAME with Win32_ComputerSystem.Domain (set on
    #    AD-joined boxes, or to "WORKGROUP" otherwise -- we ignore that).
    try {
        $domain = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
        if ($domain -and $domain -ne 'WORKGROUP' -and $domain -ne '' -and $domain.Contains('.')) {
            return "$env:COMPUTERNAME.$domain"
        }
    } catch { }

    # 3) DNS suffix from network interface
    try {
        $dnsSuffix = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList | Where-Object { $_ } | Select-Object -First 1
        if ($dnsSuffix) {
            return "$env:COMPUTERNAME.$dnsSuffix"
        }
    } catch { }

    # 4) Bare short name -- caller will likely want to override.
    return $env:COMPUTERNAME
}

function Resolve-Hostname {
    Write-Step "Gateway hostname"
    $detected = Get-DetectedFqdn
    $Script:EffHostname = if ($Hostname) { $Hostname } else {
        Read-TextPrompt "Hostname (URL workstations will use)" $detected
    }
    Write-Ok "Hostname: $($Script:EffHostname)"
}

function Resolve-TlsMode {
    Write-Step "TLS mode"
    if ($Tls) {
        $Script:EffTls = $Tls
    } elseif ($Yes.IsPresent) {
        $Script:EffTls = 'auto'
    } else {
        Write-Host "    1) auto         Caddy with local CA (recommended for LAN). Self-signed,"
        Write-Host "                    workstations install /caddy-ca.crt once."
        Write-Host "    2) letsencrypt  Caddy with Let's Encrypt (needs public DNS + ports 80/443)."
        Write-Host "    3) none         No TLS. You bring your own reverse proxy."
        $choice = Read-TextPrompt "Choose mode (1/2/3)" "1"
        switch ($choice) {
            { $_ -in '1','auto' }        { $Script:EffTls = 'auto' }
            { $_ -in '2','letsencrypt' } { $Script:EffTls = 'letsencrypt' }
            { $_ -in '3','none' }        { $Script:EffTls = 'none' }
            default                      { Throw-Stop "Unknown TLS mode: $choice" }
        }
    }
    Write-Ok "TLS: $($Script:EffTls)"
}

function Resolve-Port {
    Write-Step "Application port"
    $suggested = if ($Script:EffTls -eq 'none') { $DEFAULT_PORT_HTTP } else { $DEFAULT_PORT_TLS }
    $Script:EffPort = if ($Port) { $Port } else {
        [int](Read-TextPrompt "Port (will be checked for availability)" "$suggested")
    }
    if ($Script:EffPort -lt 1 -or $Script:EffPort -gt 65535) {
        Throw-Stop "Port out of range: $($Script:EffPort)"
    }
    if (Test-PortFree -P $Script:EffPort) {
        Write-Ok "Port $($Script:EffPort) is free"
    } else {
        Throw-Stop "Port $($Script:EffPort) is already in use. Run 'Get-NetTCPConnection -LocalPort $($Script:EffPort)' to see what's there, free it, or pick a different port (-Port)."
    }
}

function Resolve-License {
    Write-Step "License file"
    # License is delivered out-of-band by Solfins (email) and is NOT bundled
    # with the installer. It's OPTIONAL at install time -- the gateway starts
    # in an "awaiting license" state if license.lic is empty; the customer
    # can drop the real file in later + restart the service. This decouples
    # ordering license from "I want to spin up the stack now".
    $Script:EffLicense = if ($License) { $License } else {
        Read-TextPrompt "Path to license.lic from Solfins (leave empty if you'll add it later)" ''
    }
    if (-not $Script:EffLicense) {
        Write-Ok "License: will be added later (gateway starts in 'awaiting license' state)"
        return
    }
    if (-not (Test-Path $Script:EffLicense)) {
        Throw-Stop "License file not found: $($Script:EffLicense)"
    }
    $size = (Get-Item $Script:EffLicense).Length
    Write-Ok "License found: $($Script:EffLicense) ($size bytes)"
}

function Resolve-Telemetry {
    Write-Step "Telemetry"
    if ($Telemetry) {
        $Script:EffTelemetry = $Telemetry
    } else {
        Write-Host "    Anonymous hourly ping with version + opaque license hash."
        Write-Host "    No BOM data, no credentials, no usage. See INSTALL.md 'Privacy & telemetry'"
        Write-Host "    for the full payload. Toggleable later in Settings."
        $yn = Read-YesNo "Enable telemetry?" "y"
        $Script:EffTelemetry = if ($yn -eq 'y') { 'on' } else { 'off' }
    }
    Write-Ok "Telemetry: $($Script:EffTelemetry)"
}

function Show-Helper-Note {
    Write-Step "Apply Update host helper"
    Write-Substep "Skipped on Windows -- the ADR-015 Phase 2(a) helper is systemd-only for v1."
    Write-Substep "The web UI's Settings -> Updates card will fall back to its 'Copy SSH command'"
    Write-Substep "UX, or you can run 'docker compose pull && up -d' manually from the install dir."
    Write-Ok "Helper: skip (Windows v1 limitation)"
}

#--- File writing -----------------------------------------------------------

function New-PostgresPassword {
    Write-Step "Generating Postgres password"
    # 32 hex chars (128 bits of entropy). Get-Random with a byte buffer is
    # cryptographically weak by default; use [System.Security.Cryptography]
    # for proper entropy.
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Script:EffPostgresPassword = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
    Write-Ok "Generated 32-char password (saved to .env after write)"
}

function Write-ComposeYml {
    $tlsNone = ($Script:EffTls -eq 'none')
    $telemBool = if ($Script:EffTelemetry -eq 'on') { 'true' } else { 'false' }

    $portsBlock = ''
    if ($tlsNone) {
        $portsBlock = @"
    ports:
      - "$($Script:EffPort):5000"
"@
    }

    $content = @"
# Generated by 3dx-gateway install.ps1 v$INSTALLER_VERSION. Customer can edit but
# regeneration via reinstall will overwrite.

services:
  app:
    image: $GHCR_IMAGE
    container_name: 3dx-gateway-app
    restart: unless-stopped
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ConnectionStrings__BomExplorer: "Host=postgres;Port=5432;Database=bom_explorer;Username=bomapp;Password=`${POSTGRES_PASSWORD}"
      Telemetry__Enabled: "$telemBool"
$portsBlock
    volumes:
      - app_data:/app/data
      - ./license.lic:/app/license.lic:ro
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/api/license/status"]
      interval: 30s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:16-alpine
    container_name: 3dx-gateway-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: bom_explorer
      POSTGRES_USER: bomapp
      POSTGRES_PASSWORD: `${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bomapp -d bom_explorer"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
  app_data:
"@
    Set-Content -Path (Join-Path $Script:EffInstallDir 'docker-compose.yml') -Value $content -Encoding UTF8 -NoNewline:$false
}

function Write-CaddyOverlay {
    $overlay = @"
# Caddy reverse proxy overlay -- TLS termination.
services:
  caddy:
    image: caddy:2.9-alpine
    container_name: 3dx-gateway-caddy
    restart: unless-stopped
    ports:
      - "$($Script:EffPort):443"
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app

volumes:
  caddy_data:
  caddy_config:
"@
    Set-Content -Path (Join-Path $Script:EffInstallDir 'docker-compose.tls.yml') -Value $overlay -Encoding UTF8

    if ($Script:EffTls -eq 'letsencrypt') {
        $caddyfile = @"
$($Script:EffHostname) {
    reverse_proxy app:5000
}
"@
    } else {
        $caddyfile = @"
$($Script:EffHostname) {
    tls internal
    reverse_proxy app:5000
}

# Expose the local CA so workstations can install it once.
:80 {
    handle /caddy-ca.crt {
        root * /data/caddy/pki/authorities/local
        rewrite * /root.crt
        file_server
    }
    redir /* https://$($Script:EffHostname){uri}
}
"@
    }
    Set-Content -Path (Join-Path $Script:EffInstallDir 'Caddyfile') -Value $caddyfile -Encoding UTF8
}

function Write-EnvFile {
    $envContent = @"
# 3DX Gateway environment -- generated $(Get-Date -Format 'o') by install.ps1 v$INSTALLER_VERSION.
# Keep this file out of version control; POSTGRES_PASSWORD is sensitive.
POSTGRES_PASSWORD=$($Script:EffPostgresPassword)
HOSTNAME=$($Script:EffHostname)
APP_PORT=$($Script:EffPort)
TLS_MODE=$($Script:EffTls)
TELEMETRY=$($Script:EffTelemetry)
"@
    $envPath = Join-Path $Script:EffInstallDir '.env'
    Set-Content -Path $envPath -Value $envContent -Encoding UTF8

    # NTFS ACL: restrict to local Administrators + SYSTEM. .env contains the
    # generated Postgres password.
    $acl = Get-Acl $envPath
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', 'FullControl', 'Allow')
    $system = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
    $acl.SetAccessRule($admins)
    $acl.SetAccessRule($system)
    Set-Acl -Path $envPath -AclObject $acl
}

function Write-Files {
    Write-Step "Writing files to $($Script:EffInstallDir)"
    New-Item -ItemType Directory -Force -Path $Script:EffInstallDir | Out-Null
    Write-ComposeYml
    Write-Ok "docker-compose.yml"
    if ($Script:EffTls -ne 'none') {
        Write-CaddyOverlay
        Write-Ok "docker-compose.tls.yml + Caddyfile ($($Script:EffTls))"
    }
    Write-EnvFile
    Write-Ok ".env (ACL: Administrators + SYSTEM only)"
    $licDest = Join-Path $Script:EffInstallDir 'license.lic'
    if ($Script:EffLicense) {
        Copy-Item -Path $Script:EffLicense -Destination $licDest -Force
        Write-Ok "license.lic copied"
    } else {
        # Empty placeholder so the bind-mount in docker-compose.yml has
        # something to point at. Backend's LicenseService will see a 0-byte
        # file and report "license invalid"; the web UI then shows the
        # "awaiting license" state until the real file is dropped in.
        Set-Content -Path $licDest -Value '' -Encoding ASCII
        Write-Ok "license.lic placeholder (empty -- copy the real one from Solfins later)"
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Script:EffInstallDir 'data') | Out-Null
}

#--- Action -----------------------------------------------------------------

function Get-ComposeFlags {
    $flags = '-f docker-compose.yml'
    if ($Script:EffTls -ne 'none') {
        $flags += ' -f docker-compose.tls.yml'
    }
    return $flags
}

function Start-Stack {
    Write-Step "Pulling images + starting containers (this takes 30-90 s)"
    Push-Location $Script:EffInstallDir
    try {
        $flags = Get-ComposeFlags
        # We can't use & docker compose -f X -f Y up -d directly because
        # PowerShell doesn't expand $flags as multiple args. Use cmd /c
        # to let cmd parse the string.
        $cmd = "docker compose $flags up -d"
        cmd /c $cmd
        if ($LASTEXITCODE -ne 0) {
            Throw-Stop "docker compose up -d exited with code $LASTEXITCODE"
        }
        Write-Ok "Stack started"
    } finally {
        Pop-Location
    }

    # Wait for app health up to 90 s. Probe from the host via curl-like
    # Invoke-WebRequest -- in-container probe is unreliable because the
    # backend image doesn't bundle curl. For HTTPS use FQDN (Caddy's
    # `tls internal` cert is issued for exactly that name); for HTTP
    # localhost works.
    $url = Get-CheckUrl
    $passed = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            # PS 5.1 default validates the cert; skip via -SkipCertificateCheck
            # on PS 7+, or by overriding the ServerCertificateValidationCallback
            # on PS 5.1.
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -SkipCertificateCheck
            } else {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
            }
            if ($r.StatusCode -eq 200) { $passed = $true; break }
        } catch {
            Start-Sleep -Seconds 3
            continue
        }
        Start-Sleep -Seconds 3
    }
    if ($passed) {
        Write-Ok "Backend healthcheck passed"
    } else {
        Write-Warn2 "Backend didn't pass healthcheck within 90 s. Containers are up; check logs: docker logs 3dx-gateway-app"
    }
}

function Get-CheckUrl {
    # URL used by health-wait + smoke test. HTTP -> localhost; HTTPS -> FQDN
    # (because Caddy's tls-internal cert is issued for $EffHostname, not
    # localhost).
    if ($Script:EffTls -eq 'none') {
        "http://localhost:$($Script:EffPort)/api/license/status"
    } else {
        "https://$($Script:EffHostname):$($Script:EffPort)/api/license/status"
    }
}

function Get-BrowserUrl {
    # https://host/ for the standard 443; otherwise include the explicit port.
    if ($Script:EffTls -eq 'none') {
        if ($Script:EffPort -eq 80) { "http://$($Script:EffHostname)/" } else { "http://$($Script:EffHostname):$($Script:EffPort)/" }
    } else {
        if ($Script:EffPort -eq 443) { "https://$($Script:EffHostname)/" } else { "https://$($Script:EffHostname):$($Script:EffPort)/" }
    }
}

function Invoke-SmokeTest {
    Write-Step "Smoke test"
    $url = Get-CheckUrl
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -SkipCertificateCheck
        } else {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
        }
        if ($r.StatusCode -eq 200) {
            Write-Ok "$url returned 200"
            $body = $r.Content
            if ($body.Length -gt 200) { $body = $body.Substring(0, 200) + '...' }
            Write-Substep $body
        } else {
            Write-Warn2 "$url returned $($r.StatusCode) (probably DNS / cert trust -- check inside the LAN)"
        }
    } catch {
        Write-Warn2 "Could not reach $url`: $($_.Exception.Message)"
    }
}

function Show-Summary {
    Write-Hr
    Write-Host ''
    Write-Host '[OK] 3DX Gateway installed.' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Open in browser:  $(Get-BrowserUrl)"
    Write-Host "  Install dir:      $($Script:EffInstallDir)"
    Write-Host "  Compose flags:    $(Get-ComposeFlags)"
    Write-Host "  Logs:             docker logs -f 3dx-gateway-app"
    Write-Host ''

    if ($Script:EffTls -eq 'auto') {
        Write-Host '  TLS (local CA):  Each workstation must install the Caddy CA once.' -ForegroundColor Yellow
        Write-Host "                   On the workstation, run as admin:"
        Write-Host "                     curl -O http://$($Script:EffHostname)/caddy-ca.crt"
        Write-Host "                     certutil -addstore -f Root caddy-ca.crt"
        Write-Host "                   CadBridge Setup.bat does this automatically."
        Write-Host ''
    }

    Write-Host '  Auto-start:' -ForegroundColor Yellow
    Write-Host '    Containers use restart: unless-stopped so they survive Docker restarts.'
    Write-Host '    For host-reboot auto-start, ensure Docker Desktop is set to autostart with'
    Write-Host '    Windows (Docker Desktop settings -> General -> Start when you log in).'
    Write-Host '    Or use Task Scheduler: trigger "At startup", action "docker compose -f' "$($Script:EffInstallDir)\docker-compose.yml" 'up -d".'
    Write-Host ''

    if (-not $Script:EffLicense) {
        Write-Host '  License pending:' -ForegroundColor Yellow
        Write-Host '    The gateway is running but will refuse logins until license.lic is'
        Write-Host '    provided. When Solfins emails it, drop it in place and restart:'
        Write-Host "      Copy-Item C:\path\to\license.lic $($Script:EffInstallDir)\license.lic"
        Write-Host "      docker compose -f $($Script:EffInstallDir)\docker-compose.yml restart app"
        Write-Host ''
    }
    Write-Host '  Next steps:'
    Write-Host '    1. Open the URL above + log in with your 3DExperience credentials'
    Write-Host '    2. Settings -> Pantheon credentials (if you use the ERP sync module)'
    Write-Host '    3. Distribute CadBridge to each workstation (link on the home page)'
    Write-Host ''
    Write-Host '  Customer install doc:'
    Write-Host '    https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/INSTALL.md'
    Write-Host ''
    Write-Hr
}

function Confirm-Summary {
    if ($Yes.IsPresent) { return }
    Write-Hr
    Write-Host ''
    Write-Host '  Ready to install:' -ForegroundColor Cyan
    Write-Host "    install dir:  $($Script:EffInstallDir)"
    Write-Host "    hostname:     $($Script:EffHostname)"
    Write-Host "    port:         $($Script:EffPort)"
    Write-Host "    TLS:          $($Script:EffTls)"
    $licDisplay = if ($Script:EffLicense) { $Script:EffLicense } else { '(pending -- add later from Solfins email)' }
    Write-Host "    license:      $licDisplay"
    Write-Host "    telemetry:    $($Script:EffTelemetry)"
    Write-Host "    helper:       skip (Windows v1)"
    $yn = Read-YesNo 'Proceed?' 'y'
    if ($yn -ne 'y') {
        Throw-Stop 'Cancelled.'
    }
}

#--- Main -------------------------------------------------------------------

function Main {
    Show-Banner
    Require-Admin
    Test-OS
    Test-Docker
    Test-Disk
    Test-Ram
    Resolve-InstallDir
    Resolve-Hostname
    Resolve-TlsMode
    Resolve-Port
    Resolve-License
    Resolve-Telemetry
    Show-Helper-Note
    Confirm-Summary

    if ($DryRun.IsPresent) {
        Write-Step 'DRY RUN -- would write files + pull images. Exiting.'
        return
    }

    New-PostgresPassword
    Write-Files
    Start-Stack
    Invoke-SmokeTest
    Show-Summary
}

Main
