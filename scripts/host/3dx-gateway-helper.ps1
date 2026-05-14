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

$HelperVersion = '1.0.0'
$StateDir = "$env:ProgramData\3dx-gateway"
$StatusFile = "$StateDir\status.json"
$LogFile = "$StateDir\last-apply.log"
$TokenFile = "$StateDir\helper-token.txt"

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}

if (-not (Test-Path $TokenFile)) {
    throw "Token file $TokenFile not found. Run install-helper.ps1 first to generate one."
}

$token = (Get-Content -Path $TokenFile -Raw -Encoding UTF8).Trim()
if (-not $token) {
    throw "Token file $TokenFile is empty. Re-run install-helper.ps1."
}

function Write-StatusFile {
    param([string]$Content)
    # Atomic write so STATUS reads never see a half-written file.
    $tmp = "$StatusFile.tmp"
    Set-Content -Path $tmp -Value $Content -Encoding UTF8 -NoNewline
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
    # never sees "idle".
    Write-StatusFile "{`"stage`":`"pulling`",`"startedAt`":`"$(Get-NowIso)`"}"

    $argsList = @(
        '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-Command', @"
`$ErrorActionPreference = 'Continue'
`$statusFile = '$StatusFile'
`$logFile    = '$LogFile'
`$installDir = '$InstallDir'
`$composeFiles = '$ComposeFiles' -split ' '
`$composeFlags = @()
foreach (`$f in `$composeFiles) {
    if (`$f) { `$composeFlags += @('-f', `$f) }
}

function Iso { (Get-Date).ToUniversalTime().ToString('o') }
function Write-Status(`$json) {
    `$tmp = `"`$statusFile.tmp`"
    Set-Content -Path `$tmp -Value `$json -Encoding UTF8 -NoNewline
    Move-Item -Path `$tmp -Destination `$statusFile -Force
}

`$null = New-Item -ItemType File -Force -Path `$logFile
Set-Location `$installDir
& docker compose `$composeFlags pull *>> `$logFile
if (`$LASTEXITCODE -ne 0) {
    Write-Status (`"{`\`"stage`\`":`\`"error`\`",`\`"finishedAt`\`":`\`"`$(Iso)`\`",`\`"error`\`":`\`"docker compose pull failed`\`",`\`"logPath`\`":`\`"`$(`$logFile -replace '\\','\\\\')`\`"}`")
    exit 1
}
Write-Status (`"{`\`"stage`\`":`\`"restarting`\`",`\`"startedAt`\`":`\`"`$(Iso)`\`"}`")
& docker compose `$composeFlags up -d *>> `$logFile
if (`$LASTEXITCODE -ne 0) {
    Write-Status (`"{`\`"stage`\`":`\`"error`\`",`\`"finishedAt`\`":`\`"`$(Iso)`\`",`\`"error`\`":`\`"docker compose up failed`\`",`\`"logPath`\`":`\`"`$(`$logFile -replace '\\','\\\\')`\`"}`")
    exit 1
}
Write-Status (`"{`\`"stage`\`":`\`"done`\`",`\`"finishedAt`\`":`\`"`$(Iso)`\`"}`")
"@
    )

    # Detach via Start-Process so this handler can return immediately. The
    # child process gets its own console (hidden) and survives our exit.
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru | Out-Null
}

function Invoke-HelperCommand {
    param([string]$Line)

    $parts = $Line -split ' ', 2
    $cmd = if ($parts.Length -gt 0) { $parts[0].Trim() } else { '' }
    $providedToken = if ($parts.Length -gt 1) { $parts[1].Trim() } else { '' }

    # PING + STATUS could be read-only-no-auth, but for simplicity require
    # the token on every command. Removes one think-step for the gateway side.
    if ($providedToken -ne $token) {
        return '{"error":"unauthorized"}'
    }

    switch ($cmd) {
        'PING' {
            return "{`"ok`":true,`"helperVersion`":`"$HelperVersion`"}"
        }
        'STATUS' {
            if (Test-Path $StatusFile) {
                return (Get-Content -Path $StatusFile -Raw -Encoding UTF8).Trim()
            }
            return '{"stage":"idle"}'
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
$listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
$listener.Start()
Write-Host "3dx-gateway-helper.ps1 v$HelperVersion listening on $BindAddress`:$Port"
Write-Host "  install dir:   $InstallDir"
Write-Host "  compose files: $ComposeFiles"
Write-Host "  state dir:     $StateDir"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.NoDelay = $true
            $client.SendTimeout = 5000
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 1024, $true)
            $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8, 1024, $true)
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
} finally {
    $listener.Stop()
}
