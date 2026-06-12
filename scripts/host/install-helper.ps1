<#
.SYNOPSIS
Install the 3DX Gateway Apply Update helper as a Windows Scheduled Task.

.DESCRIPTION
Companion of 3dx-gateway-helper.ps1. Run ONCE during gateway install (called
by install.ps1) or manually by an admin who wants to enable the one-click
Apply Update button after the fact.

What this script does:
  1. Generates a 32-byte random token (cryptographic RNG).
  2. Writes the token to %PROGRAMDATA%\3dx-gateway\helper-token.txt with
     restrictive ACL (Administrators + SYSTEM full, no Users entry).
  3. Copies 3dx-gateway-helper.ps1 to %PROGRAMDATA%\3dx-gateway\helper.ps1.
  4. Registers a Windows Scheduled Task "3dx-gateway-helper" that runs the
     helper at machine startup as SYSTEM with RunLevel=Highest.
  5. Starts the task immediately (so the helper is reachable right after
     install, without a reboot).

Caller can read the generated token afterwards from helper-token.txt and
inject it into the gateway container as the HELPER_TOKEN env var.

.PARAMETER InstallDir
The 3DX Gateway install dir (forwarded to the helper). Default:
%PROGRAMDATA%\3DX-Gateway.

.PARAMETER ComposeFiles
Space-separated list of compose files for the helper to apply. Default:
docker-compose.yml.

.PARAMETER Port
TCP port for the helper to listen on. Default: 5171 (5170 reserved for
CadBridge agent).

.PARAMETER NoStart
Register the task but don't start it now. Reboot will start it.

.EXAMPLE
PS> sudo .\install-helper.ps1 -InstallDir 'C:\ProgramData\3DX-Gateway' `
        -ComposeFiles "docker-compose.yml docker-compose.tls.yml"
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramData\3DX-Gateway",
    [string]$ComposeFiles = "docker-compose.yml",
    [int]$Port = 5171,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$StateDir       = "$env:ProgramData\3dx-gateway"
$HelperPath     = "$StateDir\helper.ps1"
$TokenPath      = "$StateDir\helper-token.txt"
$TaskName       = "3dx-gateway-helper"
$ScriptSource   = Join-Path $PSScriptRoot '3dx-gateway-helper.ps1'

#--- Pre-flight -------------------------------------------------------------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw "install-helper.ps1 must run elevated (Administrator)."
}

if (-not (Test-Path $ScriptSource)) {
    throw "Source helper script not found: $ScriptSource (this script must run from scripts\host\)."
}

Write-Host "==> Installing 3DX Gateway Apply Update helper"

#--- State dir + token ------------------------------------------------------

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}

# Generate a 32-byte cryptographic random token (256 bits, hex-encoded =
# 64 chars). [Guid]::NewGuid() is a UUID, NOT cryptographic random; use the
# RandomNumberGenerator class.
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''
Set-Content -Path $TokenPath -Value $token -Encoding UTF8 -NoNewline

# Lock down ACL: Administrators + SYSTEM only. SYSTEM is required because
# the helper Scheduled Task runs under that principal.
$acl = Get-Acl $TokenPath
$acl.SetAccessRuleProtection($true, $false)
$admins = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Administrators', 'FullControl', 'Allow')
$system = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')
$acl.SetAccessRule($admins)
$acl.SetAccessRule($system)
Set-Acl -Path $TokenPath -AclObject $acl
Write-Host "    [OK] token written to $TokenPath (Admins+SYSTEM only)"

# Same ACL for the helper script + state dir parent. Less critical but
# defense in depth.
Copy-Item -Path $ScriptSource -Destination $HelperPath -Force
$acl2 = Get-Acl $HelperPath
$acl2.SetAccessRuleProtection($true, $false)
$acl2.SetAccessRule($admins)
$acl2.SetAccessRule($system)
Set-Acl -Path $HelperPath -AclObject $acl2
Write-Host "    [OK] helper script copied to $HelperPath"

#--- Scheduled Task ---------------------------------------------------------

# If a previous version of the task is registered, remove it cleanly. This
# makes reinstall idempotent.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "    [..] removing previous task registration"
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# A prior helper process may still be LISTENING on the port. Unregister-ScheduledTask
# removes the task definition but does NOT kill the running powershell.exe, and
# Stop-ScheduledTask can race it -- so the old listener can keep the port. If it does,
# the freshly-started task (with the NEW token) can't bind, and the stale process
# answers PINGs with the OLD token => {"error":"unauthorized"} even though the token
# files are correct (the exact symptom seen 2026-06-12). Kill whatever still holds the
# port so the new task binds cleanly with the new token.
try {
    $stale = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($procId in $stale) {
        try {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            Write-Host "    [..] killed stale helper still listening on port $Port (PID $procId)"
        } catch { }
    }
    if ($stale) { Start-Sleep -Milliseconds 700 }
} catch { }

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HelperPath`" -InstallDir `"$InstallDir`" -ComposeFiles `"$ComposeFiles`" -Port $Port"

$trigger = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval ([TimeSpan]::FromMinutes(1))

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "3DX Gateway Apply Update helper -- listens on TCP $Port for the gateway container to trigger backend updates." | Out-Null
Write-Host "    [OK] Scheduled Task '$TaskName' registered (AtStartup, runs as SYSTEM)"

#--- Firewall ---------------------------------------------------------------

# The gateway CONTAINER reaches the helper over host.docker.internal:$Port, i.e.
# from the Docker NAT subnet -- NOT loopback. On Windows Server the host firewall
# blocks inbound by default (same class of failure we hit for the published web
# ports), so without this rule the container's connect times out and the web UI
# shows "one-click update not available" even though the helper is healthy (the
# install-time PING below uses 127.0.0.1, which is exempt, so it misleadingly
# passes). Open inbound TCP $Port. The bearer token is the real auth boundary --
# the helper rejects any request without it and can only run
# `docker compose pull && up -d` against the install's compose set, never
# arbitrary commands. Idempotent (same-named rule removed first) and non-fatal
# (a disabled firewall service must not abort the helper install). To tighten,
# scope -RemoteAddress to the Docker subnet after install.
$fwName = "3DX Gateway Helper TCP $Port"
try {
    Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $fwName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
    Write-Host "    [OK] Firewall: inbound TCP $Port allowed ('$fwName')"
} catch {
    Write-Warning "    Could not add firewall rule for TCP $Port`: $($_.Exception.Message)"
    Write-Host "    Add it by hand if the web UI still shows 'one-click not available': New-NetFirewallRule -DisplayName '$fwName' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow"
}

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
    # Give the listener ~2 s to bind.
    Start-Sleep -Seconds 2

    # Sanity probe.
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(3000)) {
            throw "Connect timed out"
        }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
        $writer.NewLine = "`n"
        $writer.WriteLine("PING $token")
        $writer.Flush()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $response = $reader.ReadLine()
        $client.Close()
        if ($response -match '"ok"\s*:\s*true') {
            Write-Host "    [OK] PING -> $response"
        } else {
            Write-Warning "    Helper responded but body unexpected: $response"
        }
    } catch {
        Write-Warning "    Could not reach helper on 127.0.0.1:$Port -- task may still be starting. Check Task Scheduler. Error: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done."
Write-Host "  Helper token is at: $TokenPath"
Write-Host "  Helper status file: $StateDir\status.json"
Write-Host "  Last apply log:     $StateDir\last-apply.log"
Write-Host ""
Write-Host "To uninstall, run scripts\host\uninstall-helper.ps1."
