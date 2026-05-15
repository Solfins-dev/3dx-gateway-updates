<#
.SYNOPSIS
3DX Gateway -- Windows Server installer (initial setup).

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
  - Optional Apply Update host helper: a PowerShell Scheduled Task running
    as SYSTEM that listens on TCP 5171 and runs `docker compose pull && up
    -d` on demand. The gateway container reaches it via host.docker.internal
    with a bearer token. Equivalent to the Linux systemd helper.
  - Port check via Get-NetTCPConnection instead of ss.
  - Docker auto-install IS supported (v1.2.0+) on Win10/11 + Server 2022+:
    if `docker` is missing the script offers to download Docker Desktop
    (~600 MB), enable WSL2 + VM Platform features (reboot required first
    time), run the silent install (--quiet --accept-license --backend=wsl-2
    --always-run-service), and wait for the daemon. Server 2019 and below
    fall back to the manual hint (Mirantis MCR / Docker Engine via WSL2).
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
on | off. Anonymous hourly version ping. Default: on.

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
    [ValidateSet('on', 'off')]
    [string]$Helper,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Constants
$INSTALLER_VERSION   = '1.4.0'
$DOCKER_INSTALLER_URL = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
$WIN_BUILD_SERVER_2022 = 20348
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
$Script:EffHelper           = $null
$Script:EffHelperToken      = $null
$Script:EffPostgresPassword = $null
# Detected by Test-OS / Test-Docker; conservative defaults so downstream
# checks behave sanely even if those steps are skipped (e.g. -DryRun edge).
$Script:IsServer            = $false
$Script:DockerFlavor        = 'unknown'

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
    # ProductType: 1 = Workstation, 2 = Domain Controller, 3 = Server.
    # Server installs typically use Mirantis MCR or Docker Engine via WSL2,
    # not Docker Desktop -- branch the install hints + autostart guidance
    # accordingly.
    $Script:IsServer = ($os.ProductType -ne 1)
    $kind = if ($Script:IsServer) { 'Server' } else { 'Workstation' }
    Write-Ok "$caption (build $build, $kind)"
}

function Test-CanAutoInstallDocker {
    # Docker Desktop's silent installer supports Win10/11 (build 19044+) and
    # Server 2022+. Server 2019 and below: no go (Docker Desktop unsupported).
    if (-not $Script:IsServer) { return $true }
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    return ($build -ge $WIN_BUILD_SERVER_2022)
}

function Show-DockerManualHints {
    if ($Script:IsServer) {
        Write-Substep "On Windows Server, install one of:"
        Write-Substep "  * Mirantis Container Runtime (MCR -- Docker Engine fork for Server)."
        Write-Substep "    See https://docs.mirantis.com/mcr/"
        Write-Substep "  * Docker Engine via WSL2 (works on Server 2022 with WSL2 enabled)"
        Write-Substep "  * Docker Desktop -- supported on Server 2022+ but uncommon in prod"
    } else {
        Write-Substep "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
    }
}

function Test-WSL2Ready {
    # Both features must be Enabled AND `wsl --status` must succeed (means
    # WSL2 kernel is installed + default version is 2). After a reboot, the
    # LxssManager service can take 30-60 s to initialise -- if `wsl --status`
    # fires too early it returns non-zero with no useful output, which used
    # to push us into a reboot loop. Retry up to 6 x 5 s before giving up.
    try {
        $wsl = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    } catch {
        return $false
    }
    if ($wsl.State -ne 'Enabled' -or $vmp.State -ne 'Enabled') { return $false }

    for ($i = 0; $i -lt 6; $i++) {
        $null = wsl --status 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -eq 0) {
            Write-Substep "wsl --status not responding yet (post-reboot init can take ~30 s); waiting..."
        }
        Start-Sleep -Seconds 5
    }
    Write-Warn2 "wsl --status kept failing after 30 s. Run 'wsl --status' manually to see why."
    return $false
}

function Install-WSL2 {
    Write-Step "Enabling WSL2 + Virtual Machine Platform"
    Write-Substep "This typically takes 1-3 min and REQUIRES A REBOOT before Docker can run."

    # Modern Windows (build 22000+) supports `wsl --install --no-distribution`
    # which enables both features + sets WSL2 as default in one shot. Older
    # builds need the optional-feature path.
    $useWslCli = $false
    try {
        $help = wsl --help 2>&1 | Out-String
        if ($help -match '--no-distribution') { $useWslCli = $true }
    } catch { }

    if ($useWslCli) {
        & wsl --install --no-distribution
        if ($LASTEXITCODE -ne 0) {
            Throw-Stop "wsl --install failed (exit $LASTEXITCODE). Run it manually + reboot, then re-run this installer."
        }
    } else {
        # Legacy path: enable each feature separately.
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart | Out-Null
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
    }
    Write-Ok "WSL2 features enabled (reboot pending)"
    Write-Hr
    Write-Host ""
    Write-Host "  REBOOT REQUIRED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  WSL2 features were just enabled but the kernel + Docker Desktop won't"
    Write-Host "  run until you reboot. After the reboot:"
    Write-Host ""
    Write-Host "    1. Open an elevated PowerShell"
    Write-Host "    2. Re-run the same install command -- the installer will detect that"
    Write-Host "       WSL2 is now ready and continue with Docker Desktop install."
    Write-Host ""
    Throw-Stop "Reboot now (Restart-Computer) and re-run this script."
}

function Get-DockerDesktopInstaller {
    # Downloads (or re-uses cached) Docker Desktop Installer.exe to %TEMP%.
    # Returns the local path. Same logic for both fresh-install + update.
    $dst = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    Write-Step "Downloading Docker Desktop installer (~600 MB)"
    if (Test-Path $dst) { Remove-Item -Force $dst }
    # IWR shows progress automatically. UseBasicParsing avoids the IE engine
    # init that fails on freshly-installed Server cores.
    Invoke-WebRequest -Uri $DOCKER_INSTALLER_URL -OutFile $dst -UseBasicParsing
    $sizeMb = [math]::Round((Get-Item $dst).Length / 1MB, 1)
    Write-Ok "Downloaded $sizeMb MB to $dst"
    return $dst
}

function Invoke-DockerDesktopInstaller {
    # Runs the silent installer. Same flag set works for fresh install and
    # in-place upgrade -- Docker Desktop's installer detects existing version.
    param([string]$InstallerPath, [string]$Action = 'install')
    Write-Step "$Action Docker Desktop (silent, ~3-5 min, no UI)"
    $installArgs = @(
        'install',
        '--quiet',
        '--accept-license',
        '--backend=wsl-2',
        '--always-run-service'
    )
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    return $proc.ExitCode
}

function Install-DockerDesktop {
    if (-not (Test-WSL2Ready)) {
        Install-WSL2  # throws + exits with reboot message
    }
    Write-Ok "WSL2 ready"
    Update-WSL  # idempotent; pulls the latest WSL2 kernel before Docker runs

    $dst = Get-DockerDesktopInstaller
    $exit = Invoke-DockerDesktopInstaller -InstallerPath $dst -Action 'Installing'
    if ($exit -ne 0) {
        Throw-Stop "Docker Desktop installer exited with code $exit. Run the installer manually for diagnostics: $dst"
    }
    Write-Ok "Docker Desktop installed"

    Start-DockerDaemon
    Wait-DockerDaemon
}

function Start-DockerDaemon {
    # On Windows Server, Docker Desktop's silent install completes but the
    # daemon doesn't auto-spawn until the GUI is launched at least once
    # (--always-run-service mostly applies after the first UI run + reboot).
    # Three things together get the daemon up reliably without re-login:
    #   1. Add current user to docker-users (required for named-pipe access)
    #   2. Start com.docker.service (idempotent, no-op if already running)
    #   3. Start-Process Docker Desktop.exe (kicks off daemon initialization)
    #
    # Net effect: customer doesn't need to log out / log back in.

    Write-Step "Bringing Docker daemon online"

    # 1. docker-users group enrollment
    try {
        $null = & net localgroup docker-users $env:USERNAME /add 2>&1
        Write-Substep "$env:USERNAME added to docker-users (or already a member)"
    } catch {
        Write-Warn2 "net localgroup docker-users failed: $($_.Exception.Message)"
    }

    # 2. Start the underlying service if registered
    try {
        Start-Service com.docker.service -ErrorAction Stop
        Write-Substep "com.docker.service started"
    } catch {
        Write-Substep "com.docker.service: $($_.Exception.Message)"
    }

    # 3. Launch Docker Desktop UI in detached process. This step is what
    # actually creates the npipe and spawns dockerd via WSL2.
    $dockerDesktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerDesktopExe) {
        Start-Process -FilePath $dockerDesktopExe -ErrorAction SilentlyContinue
        Write-Substep "Launched Docker Desktop UI (initializes the daemon, ~30-60 s)"
    } else {
        Write-Warn2 "Docker Desktop.exe not at the expected path; daemon may need manual launch."
    }
}

function Update-DockerDesktop {
    # In-place upgrade: re-runs the silent installer. Docker Desktop's
    # installer detects existing version and upgrades if newer is shipped.
    $dst = Get-DockerDesktopInstaller
    $exit = Invoke-DockerDesktopInstaller -InstallerPath $dst -Action 'Updating'
    if ($exit -ne 0) {
        Write-Warn2 "Docker Desktop installer returned $exit; existing Docker may still work. Inspect 'docker version'."
        return
    }
    Write-Ok "Docker Desktop updated"
    # Service restart for the new binaries to take effect.
    try { Restart-Service com.docker.service -ErrorAction Stop } catch {
        Write-Warn2 "Could not restart com.docker.service: $($_.Exception.Message). Restart Docker Desktop manually."
    }
    Wait-DockerDaemon
}

function Update-WSL {
    # Idempotent. Pulls latest WSL2 kernel from Microsoft Update / web. Safe
    # to run on every install.ps1 invocation -- no kernel update needed = no
    # change. --web-download path avoids the Microsoft Store dependency
    # which Server SKUs sometimes lack.
    Write-Step "Updating WSL kernel (`wsl --update`)"
    & wsl --update --web-download 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "WSL kernel up to date"
    } else {
        # --web-download may not exist on very old wsl.exe; retry without it.
        & wsl --update 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "WSL kernel up to date"
        } else {
            Write-Warn2 "wsl --update returned $LASTEXITCODE; kept current kernel. Run 'wsl --version' to inspect."
        }
    }
}

function Wait-DockerDaemon {
    # Polls `docker info` until daemon responds (up to 3 min on cold installs
    # where Docker Desktop's first-run setup is doing WSL2 distro provisioning).
    # SilentlyContinue inside the loop suppresses the PS NativeCommandError
    # noise that surfaces while the npipe doesn't exist yet -- the real
    # signal is just $LASTEXITCODE == 0.
    Write-Step "Waiting for Docker daemon (up to 180 s; cold-install can take a while)"
    $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
    if (-not (Test-Path $dockerExe)) { $dockerExe = 'docker' }
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        for ($i = 0; $i -lt 60; $i++) {
            & $dockerExe info *>$null 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Docker daemon ready"
                return
            }
            Start-Sleep -Seconds 3
        }
    } finally {
        $ErrorActionPreference = $prevPref
    }
    Write-Hr
    Write-Host ""
    Write-Host "  DOCKER DAEMON NOT RESPONDING" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Docker Desktop is installed but the daemon hasn't come up after 3 min."
    Write-Host "  Common fixes:"
    Write-Host ""
    Write-Host "    1. Open Docker Desktop from the Start menu (or system tray) and accept"
    Write-Host "       any first-run prompts. Wait for the tray icon to stop animating."
    Write-Host ""
    Write-Host "    2. If you're not in the docker-users group:"
    Write-Host "         net localgroup docker-users `$env:USERNAME /add"
    Write-Host "       Then SIGN OUT + sign back in (group membership applies on new token)."
    Write-Host ""
    Write-Host "    3. Re-run install.bat once Docker Desktop's tray icon settles."
    Write-Host ""
    Throw-Stop "Docker daemon didn't come up in 180 s."
}

function Test-Docker {
    Write-Step "Checking Docker"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warn2 "Docker not installed."
        if (Test-CanAutoInstallDocker) {
            $yn = Read-YesNo "Install Docker Desktop now? (~600 MB download, ~5 min, may need reboot for WSL2)" "y"
            if ($yn -eq 'y') {
                Install-DockerDesktop
                # Refresh the PATH for THIS session so we can call docker
                # without the customer having to re-launch PS.
                $env:PATH += ";$env:ProgramFiles\Docker\Docker\resources\bin"
                if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                    Throw-Stop "docker.exe didn't land on PATH after install. Open a fresh elevated PowerShell and re-run this script."
                }
            } else {
                Show-DockerManualHints
                Throw-Stop "Install Docker, ensure the daemon is running, then re-run this script."
            }
        } else {
            # Server 2019 / older: no auto-install path, point at manual options.
            Show-DockerManualHints
            Throw-Stop "Install Docker, ensure the daemon is running, then re-run this script."
        }
    }
    try {
        $null = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            $hint = if ($Script:IsServer) { 'Start the Docker service (Get-Service docker | Start-Service)' } else { 'Start Docker Desktop' }
            Throw-Stop "Docker daemon is not running. $hint and re-run."
        }
    } catch {
        Throw-Stop "Docker daemon is not running: $($_.Exception.Message)"
    }
    # Detect engine flavour for downstream messaging. MCR / Docker Engine on
    # Server reports ServerVersion like "20.10.9" without "+desktop"; Docker
    # Desktop adds "+desktop.<n>" or runs OperatingSystem "Docker Desktop".
    try {
        $infoJson = (docker info --format '{{json .}}' 2>$null) | ConvertFrom-Json
        $opsys = "$($infoJson.OperatingSystem)"
        if ($opsys -like '*Docker Desktop*') {
            $Script:DockerFlavor = 'desktop'
        } elseif ($opsys -like '*Mirantis*') {
            $Script:DockerFlavor = 'mirantis'
        } else {
            $Script:DockerFlavor = 'engine'
        }
    } catch {
        $Script:DockerFlavor = 'unknown'
    }
    $v = (docker version --format '{{.Server.Version}}' 2>$null)
    Write-Ok "Docker $v ($Script:DockerFlavor, daemon running)"

    # Auto-update path for already-installed Docker. WSL kernel update is
    # silent + idempotent; Docker Desktop in-place upgrade is opt-in (default
    # N) because it's a 600 MB download we don't want to repeat on every
    # install.ps1 re-run.
    if (Test-WSL2Ready) {
        Update-WSL
    }
    if ($Script:DockerFlavor -eq 'desktop') {
        $yn = Read-YesNo "Update Docker Desktop to latest? (~600 MB download, ~5 min)" "n"
        if ($yn -eq 'y') {
            Update-DockerDesktop
            $v = (docker version --format '{{.Server.Version}}' 2>$null)
            Write-Ok "Docker now $v"
        }
    } elseif ($Script:DockerFlavor -in 'mirantis','engine') {
        Write-Substep "Update path for $($Script:DockerFlavor) is engine-managed; skipping auto-update."
    }

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

function Resolve-Helper {
    Write-Step "Apply Update host helper"
    if ($Helper) {
        $Script:EffHelper = $Helper
    } else {
        Write-Host "    Optional. Installs a PowerShell Scheduled Task that listens on TCP 5171 and"
        Write-Host "    handles one-click backend updates from the web UI (Settings -> Updates ->"
        Write-Host "    Apply Update). Without it the UI falls back to a copy-SSH-command UX."
        $yn = Read-YesNo "Install Apply Update helper?" "y"
        $Script:EffHelper = if ($yn -eq 'y') { 'on' } else { 'off' }
    }
    Write-Ok "Helper: $($Script:EffHelper)"
}

function Install-Helper {
    if ($Script:EffHelper -ne 'on') { return }
    Write-Step "Installing Apply Update host helper"

    # The helper scripts live in the public repo under scripts/host/. Fetch
    # them via Invoke-WebRequest into a temp dir, then call install-helper.ps1
    # which generates a token + registers the Scheduled Task.
    $tmpdir = Join-Path $env:TEMP "3dx-gateway-helper-$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tmpdir | Out-Null
    try {
        foreach ($f in @('3dx-gateway-helper.ps1', 'install-helper.ps1', 'uninstall-helper.ps1')) {
            $url = "$PUBLIC_REPO_BASE/scripts/host/$f"
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmpdir $f) -UseBasicParsing -ErrorAction Stop
        }
        Write-Substep "Helper scripts fetched"

        # Build the compose-files string for the helper (must match what we'd
        # pass to `docker compose -f X -f Y up -d`).
        $composeFiles = "docker-compose.yml"
        if ($Script:EffTls -ne 'none') { $composeFiles += " docker-compose.tls.yml" }
        $composeFiles += " docker-compose.helper.windows.yml"

        $installArgs = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $tmpdir 'install-helper.ps1'),
            '-InstallDir', $Script:EffInstallDir,
            '-ComposeFiles', $composeFiles,
            '-Port', '5171'
        )
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Throw-Stop "install-helper.ps1 exited with code $($proc.ExitCode)"
        }

        # Read the generated token so we can inject it into the gateway
        # container's env.
        $tokenFile = "$env:ProgramData\3dx-gateway\helper-token.txt"
        if (-not (Test-Path $tokenFile)) {
            Throw-Stop "install-helper.ps1 succeeded but $tokenFile was not created"
        }
        $Script:EffHelperToken = (Get-Content -Path $tokenFile -Raw -Encoding UTF8).Trim()
        Write-Ok "Helper installed (token captured for container env)"
    } finally {
        Remove-Item -Recurse -Force $tmpdir -ErrorAction SilentlyContinue
    }
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
      # Email-OTP onboarding path -- off by default; flip to "true" once
      # Solfins has wired up the M365 SMTP secrets on the Worker side.
      # See INSTALL.md "Onboarding flow" for the customer-side switch.
      Licensing__RequestEnabled: "`${LICENSING_REQUEST_ENABLED:-false}"
$portsBlock
    volumes:
      - app_data:/app/data
      # license.lic mounted RW so the first-run wizard can write a customer-
      # uploaded license back to disk; backend only writes signature-validated
      # content.
      - ./license.lic:/app/license.lic
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
    $helperLine = if ($Script:EffHelperToken) { "HELPER_TOKEN=$($Script:EffHelperToken)`r`n" } else { "" }
    $envContent = @"
# 3DX Gateway environment -- generated $(Get-Date -Format 'o') by install.ps1 v$INSTALLER_VERSION.
# Keep this file out of version control; POSTGRES_PASSWORD + HELPER_TOKEN are sensitive.
POSTGRES_PASSWORD=$($Script:EffPostgresPassword)
HOSTNAME=$($Script:EffHostname)
APP_PORT=$($Script:EffPort)
TLS_MODE=$($Script:EffTls)
TELEMETRY=$($Script:EffTelemetry)
# Onboarding email-OTP path. Default false: customers can only install
# via direct .lic upload (or pre-install --License). Flip to "true" after
# Solfins admin wires up the M365 SMTP path, then `docker compose up -d`.
LICENSING_REQUEST_ENABLED=false
$helperLine
"@
    $envPath = Join-Path $Script:EffInstallDir '.env'
    Set-Content -Path $envPath -Value $envContent -Encoding UTF8

    # NTFS ACL: restrict to local Administrators + SYSTEM + the operator
    # account that ran the installer (Read). .env contains the generated
    # Postgres password.
    #
    # The operator entry is the non-obvious piece: even though that user is
    # typically in Administrators, UAC strips the Admins SID from the
    # non-elevated token. Without an explicit Read ACE for the user, every
    # subsequent `docker compose up/down/logs` from a regular PowerShell
    # window fails with "Access is denied" on .env -- compose reads .env
    # client-side for variable substitution. We grant Read (not Write) so
    # editing the password still requires elevation.
    $acl = Get-Acl $envPath
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', 'FullControl', 'Allow')
    $system = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
    $operator = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", 'Read', 'Allow')
    $acl.SetAccessRule($admins)
    $acl.SetAccessRule($system)
    $acl.SetAccessRule($operator)
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
    Write-Ok ".env (ACL: Administrators + SYSTEM full; $env:USERDOMAIN\$env:USERNAME read)"
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
    if ($Script:EffHelper -eq 'on') {
        $flags += ' -f docker-compose.helper.windows.yml'
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

    # Wait for app health up to 90 s. Probe from the host via .NET HttpClient
    # -- in-container probe is unreliable because the backend image doesn't
    # bundle curl. For HTTPS use FQDN (Caddy's `tls internal` cert is issued
    # for exactly that name); for HTTP localhost works.
    #
    # We use [HttpClient] directly instead of Invoke-WebRequest because the
    # latter raises PowerShell terminating errors on connection refused /
    # premature-end during warmup, and Start-Transcript records each one as
    # a scary `PS>TerminatingError(...)` line even when try/catch swallows
    # it. .NET exceptions don't surface to the transcript engine the same
    # way, so the install log stays clean.
    $url = Get-CheckUrl
    $passed = $false
    $handler = [System.Net.Http.HttpClientHandler]::new()
    # Built-in static delegate that returns true unconditionally. Using a PS
    # scriptblock here would throw "no Runspace available" when invoked from
    # HttpClient's TLS validation thread -- the SSL handshake then fails with
    # the misleading "SSL connection could not be established".
    $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(3)
    try {
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $resp = $client.GetAsync($url).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) { $passed = $true; break }
            } catch {
                # warmup in progress; quiet retry
            }
            Start-Sleep -Seconds 3
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
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
    $handler = [System.Net.Http.HttpClientHandler]::new()
    # Built-in static delegate that returns true unconditionally. Using a PS
    # scriptblock here would throw "no Runspace available" when invoked from
    # HttpClient's TLS validation thread -- the SSL handshake then fails with
    # the misleading "SSL connection could not be established".
    $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    try {
        try {
            $resp = $client.GetAsync($url).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            if ($code -eq 200) {
                Write-Ok "$url returned 200"
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($body.Length -gt 200) { $body = $body.Substring(0, 200) + '...' }
                Write-Substep $body
            } else {
                Write-Warn2 "$url returned $code (probably DNS / cert trust -- check inside the LAN)"
            }
        } catch {
            Write-Warn2 "Could not reach $url`: $($_.Exception.Message)"
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
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
    if ($Script:IsServer) {
        Write-Host '    For host-reboot auto-start on Windows Server:'
        Write-Host '      - Docker Engine / Mirantis MCR: the docker service is set to autostart'
        Write-Host '        by the installer; verify with `Get-Service docker`. The compose stack'
        Write-Host '        relaunches via restart: unless-stopped once the daemon is up.'
        Write-Host "      - Belt-and-braces: register a Scheduled Task at boot running"
        Write-Host "        ``docker compose -f $($Script:EffInstallDir)\docker-compose.yml up -d``"
    } else {
        Write-Host '    For host-reboot auto-start, ensure Docker Desktop is set to autostart with'
        Write-Host '    Windows (Docker Desktop settings -> General -> Start when you log in).'
        Write-Host "    Or use Task Scheduler: trigger ``At startup``, action ``docker compose -f $($Script:EffInstallDir)\docker-compose.yml up -d``."
    }
    Write-Host ''

    if ($Script:EffHelper -eq 'on') {
        Write-Host '  Apply Update helper:' -ForegroundColor Yellow
        Write-Host '    Installed as Scheduled Task "3dx-gateway-helper" (runs as SYSTEM).'
        Write-Host '    To uninstall later: pwsh scripts\host\uninstall-helper.ps1 (admin).'
        Write-Host '    Helper state dir:   %PROGRAMDATA%\3dx-gateway\'
        Write-Host ''
    }

    if (-not $Script:EffLicense) {
        Write-Host '  License pending:' -ForegroundColor Yellow
        Write-Host '    The gateway is running but logins are blocked until a license.lic is'
        Write-Host '    installed. Two options when Solfins emails the file:'
        Write-Host ''
        Write-Host '      A) From your browser (no shell needed):'
        Write-Host "         Open $(Get-BrowserUrl), the first-run wizard appears -- drag/drop"
        Write-Host '         the .lic file or paste its contents. Activates instantly.'
        Write-Host ''
        Write-Host '      B) From this server (admin shell):'
        Write-Host "         Copy-Item C:\path\to\license.lic $($Script:EffInstallDir)\license.lic"
        Write-Host "         docker compose -f $($Script:EffInstallDir)\docker-compose.yml restart app"
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
    Write-Host "    helper:       $($Script:EffHelper)"
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
    Resolve-Helper
    Confirm-Summary

    if ($DryRun.IsPresent) {
        Write-Step 'DRY RUN -- would write files + install helper + pull images. Exiting.'
        return
    }

    New-PostgresPassword
    Install-Helper
    Write-Files
    Start-Stack
    Invoke-SmokeTest
    Show-Summary
}

Main
