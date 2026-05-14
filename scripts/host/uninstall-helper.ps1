<#
.SYNOPSIS
Remove the 3DX Gateway Apply Update helper Scheduled Task and state files.

.PARAMETER PurgeState
Also delete %PROGRAMDATA%\3dx-gateway\ (token, helper script, status, logs).
Without this flag we keep the directory so the next install reuses the same
state -- useful if you're reinstalling the gateway and want to preserve the
update-log audit trail.
#>

[CmdletBinding()]
param(
    [switch]$PurgeState
)

$ErrorActionPreference = 'Stop'

$TaskName = "3dx-gateway-helper"
$StateDir = "$env:ProgramData\3dx-gateway"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw "uninstall-helper.ps1 must run elevated (Administrator)."
}

Write-Host "==> Removing 3DX Gateway Apply Update helper"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "    [OK] Scheduled Task '$TaskName' unregistered"
} else {
    Write-Host "    [..] Scheduled Task '$TaskName' was not registered"
}

if ($PurgeState) {
    if (Test-Path $StateDir) {
        Remove-Item -Recurse -Force $StateDir
        Write-Host "    [OK] state dir removed: $StateDir"
    }
} else {
    Write-Host "    [..] state dir kept: $StateDir (pass -PurgeState to wipe)"
}
