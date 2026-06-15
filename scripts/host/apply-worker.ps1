<#
.SYNOPSIS
3DX Gateway Apply Update worker -- runs `docker compose pull` + `up -d` against the
AUTHORITATIVE compose set and ALWAYS writes a terminal status to status.json.

.DESCRIPTION
Forked by 3dx-gateway-helper.ps1 on APPLY. Deliberately a real .ps1 invoked with
`-File` (not an inline `-Command` here-string) so normal PowerShell param-binding /
quoting applies and a try/catch/finally can GUARANTEE a terminal status is written
even on an unexpected exit. This is the structural fix for the recurring "stuck at
pulling forever" / "app never recreated, no error reported" class.

Compose-set source of truth (drift fix):
  1. Authoritative on-disk manifest %ProgramData%\3dx-gateway\compose-set.json,
     written by install-helper.ps1 / install.ps1 -AddHelper (operator intent).
  2. If absent (cold start), derive from the live app container's compose labels.
  3. Last resort: the -Fallback* params the listener passes (the baked task args).
Every compose file is validated to exist before use -- a missing file is a
TERMINAL ERROR, never a silent fallback to a different set (silent fallback is
exactly the drift that dropped pins / overlays in the past).

.PARAMETER StateDir
%ProgramData%\3dx-gateway -- where status.json / last-apply.log / compose-set.json live.

.PARAMETER FallbackInstallDir
Cold-start working dir when neither compose-set.json nor container labels resolve.

.PARAMETER FallbackComposeFiles
Cold-start space-separated compose file list (relative to FallbackInstallDir).

.PARAMETER StepTimeoutSec
Hard per-step timeout for `pull` and `up -d`. A step that exceeds it is killed and
reported as an error instead of hanging the apply forever. Default 1200 (20 min).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateDir,
    [string]$FallbackInstallDir = "$env:ProgramData\3DX-Gateway",
    [string]$FallbackComposeFiles = "docker-compose.yml",
    [int]$StepTimeoutSec = 1200
)

$ErrorActionPreference = 'Continue'

$StatusFile   = Join-Path $StateDir 'status.json'
$LogFile      = Join-Path $StateDir 'last-apply.log'
$SetFile      = Join-Path $StateDir 'compose-set.json'
$AppService   = 'app'
$AppContainer = '3dx-gateway-app'

function Get-Iso { (Get-Date).ToUniversalTime().ToString('o') }

function Write-AppLog {
    param([string]$Message)
    try { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Iso), $Message) -Encoding UTF8 } catch { }
}

# Build status JSON via ConvertTo-Json so Windows paths / quotes / control chars are
# always validly escaped, and write it WITHOUT a BOM (the backend's System.Text.Json
# rejects a leading BOM -- the 2026-06-13 incident). Atomic via tmp + move.
function Write-Status {
    param([string]$Stage, [string]$ErrorMsg, [string]$Detail)
    $o = [ordered]@{ stage = $Stage }
    if ($script:StartedAt) { $o.startedAt = $script:StartedAt }
    if ($Stage -eq 'done' -or $Stage -eq 'error') { $o.finishedAt = (Get-Iso) }
    $o.workerPid = $PID
    # As a STRING: process StartTime.Ticks is ~18 digits; ConvertFrom-Json on PS5.1
    # parses bare JSON numbers that large as [double] and loses precision, which would
    # make the watchdog's PID-reuse tick comparison misfire and kill a healthy worker.
    $o.workerStartTicks = "$script:WorkerStartTicks"
    $o.logPath = $LogFile
    if ($ErrorMsg) { $o.error = $ErrorMsg }
    if ($Detail)   { $o.detail = $Detail }
    $json = ($o | ConvertTo-Json -Compress)
    $tmp = "$StatusFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmp -Destination $StatusFile -Force
    if ($Stage -eq 'done' -or $Stage -eq 'error') { $script:Terminal = $true }
}

function Resolve-Docker {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\resources\bin\docker.exe')
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $g = Get-Command docker -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    try { $w = (& where.exe docker 2>$null | Select-Object -First 1); if ($w) { return $w } } catch { }
    return $null
}

# Run a docker invocation in a child job with a hard timeout. `& $d @a` splats each
# arg element verbatim (no re-quoting), and we capture both streams to the log. A
# step that exceeds $TimeoutSec is killed and returns 124 so the worker can report a
# real error instead of hanging.
function Invoke-DockerStep {
    param([string]$Docker, [string[]]$DockerArgs, [string]$WorkingDir, [int]$TimeoutSec)
    $sb = {
        param($d, $a, $wd)
        if ($wd -and (Test-Path $wd)) { Set-Location $wd }
        $out = & $d @a 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    $job = Start-Job -ScriptBlock $sb -ArgumentList $Docker, $DockerArgs, $WorkingDir
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-AppLog "TIMEOUT after ${TimeoutSec}s: docker $($DockerArgs -join ' ')"
        return 124
    }
    # Receive-Job can hand back a single-element array on PS5.1; take the last object
    # so $r is the [pscustomobject], not an array (whose .ExitCode would be an array and
    # silently coerce to 0 — masking a failed step as success).
    $r = Receive-Job $job | Select-Object -Last 1
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($r -and $r.Output) { Write-AppLog ($r.Output.TrimEnd()) }
    if ($null -eq $r -or $null -eq $r.ExitCode) { return 0 }
    return [int]$r.ExitCode
}

# Resolve the compose context (project / working dir / env-file / -f files).
# Returns a hashtable or $null. Uses `--format '{{json .Config.Labels}}'` for label
# reads -- emitting JSON avoids passing a Go template with embedded double quotes to
# docker.exe, which PowerShell's native-arg quoting mangles ("function com not
# defined"). That bug is exactly why the manual `index .Config.Labels "..."` failed.
function Get-ComposeContext {
    param([string]$Docker)

    # (1) Authoritative manifest.
    if (Test-Path $SetFile) {
        try {
            $s = Get-Content -Path $SetFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $files = @($s.composeFiles)
            if ($files.Count -gt 0) {
                Write-AppLog "compose context: compose-set.json (project=$($s.project), files=$($files -join ','))"
                return @{
                    Project      = $s.project
                    WorkingDir   = $s.workingDir
                    EnvFile      = $s.envFile
                    ComposeFiles = $files
                    Source       = 'compose-set.json'
                }
            }
            Write-AppLog "compose-set.json present but composeFiles empty -- trying labels"
        } catch {
            Write-AppLog "compose-set.json unreadable ($($_.Exception.Message)) -- trying labels"
        }
    }

    # (2) Live container labels (cold start before the manifest was written).
    try {
        $labelsJson = & $Docker inspect --format '{{json .Config.Labels}}' $AppContainer 2>$null
        if ($LASTEXITCODE -eq 0 -and $labelsJson) {
            $labels = $labelsJson | ConvertFrom-Json
            $cf  = $labels.'com.docker.compose.project.config_files'
            $wd  = $labels.'com.docker.compose.project.working_dir'
            $prj = $labels.'com.docker.compose.project'
            if ($cf) {
                $files = @($cf -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $envf = if ($wd) { Join-Path $wd '.env' } else { $null }
                if ($envf -and -not (Test-Path $envf)) { $envf = $null }
                Write-AppLog "compose context: container labels (project=$prj, files=$($files -join ','))"
                return @{
                    Project      = $prj
                    WorkingDir   = $wd
                    EnvFile      = $envf
                    ComposeFiles = $files
                    Source       = 'container-labels'
                }
            }
        }
    } catch {
        Write-AppLog "label derivation failed: $($_.Exception.Message)"
    }

    # (3) Cold-start fallback: the baked task params.
    $files = @($FallbackComposeFiles -split ' ' | Where-Object { $_ } | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $FallbackInstallDir $_ }
    })
    $envf = Join-Path $FallbackInstallDir '.env'
    if (-not (Test-Path $envf)) { $envf = $null }
    Write-AppLog "compose context: cold-start fallback (dir=$FallbackInstallDir, files=$($files -join ','))"
    return @{
        Project      = (Split-Path -Leaf $FallbackInstallDir).ToLowerInvariant()
        WorkingDir   = $FallbackInstallDir
        EnvFile      = $envf
        ComposeFiles = $files
        Source       = 'fallback-params'
    }
}

#--- Main -------------------------------------------------------------------

$script:StartedAt = Get-Iso
$script:Terminal  = $false
try { $script:WorkerStartTicks = (Get-Process -Id $PID).StartTime.Ticks } catch { $script:WorkerStartTicks = 0 }

try {
    Write-Status -Stage 'pulling'
    Write-AppLog "apply-worker v1.2.0 starting (pid=$PID)"

    $docker = Resolve-Docker
    if (-not $docker) {
        Write-Status -Stage 'error' -ErrorMsg 'Docker CLI not found on the host (looked in Program Files\Docker\Docker\resources\bin and PATH).'
        return
    }
    Write-AppLog "docker: $docker"

    # Engine reachability as THIS account (SYSTEM). A docker.exe that resolves but
    # can't reach the daemon (pipe ACL / engine not started for SYSTEM) is the real
    # silent failure the opaque "not available" used to mask.
    $serverVer = (& $docker version --format '{{.Server.Version}}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverVer)) {
        Write-Status -Stage 'error' -ErrorMsg 'Docker CLI found but cannot reach the Docker engine as SYSTEM (daemon not running, or named-pipe permissions). Start Docker / Docker Desktop service and retry.'
        return
    }
    Write-AppLog "docker engine: $serverVer"

    $ctx = Get-ComposeContext -Docker $docker

    # Validate every compose file exists. A missing file => TERMINAL ERROR, never a
    # silent switch to a different set (that silent switch is the historic drift).
    $missing = @($ctx.ComposeFiles | Where-Object { -not (Test-Path $_) })
    if ($ctx.ComposeFiles.Count -eq 0) {
        Write-Status -Stage 'error' -ErrorMsg "No compose files resolved (source=$($ctx.Source)). Re-run install.ps1 -AddHelper to rewrite compose-set.json."
        return
    }
    if ($missing.Count -gt 0) {
        Write-Status -Stage 'error' -ErrorMsg "Compose file(s) missing on disk: $($missing -join '; '). Refusing to apply with a partial set (would drop overlays). Re-run install.ps1 -AddHelper."
        return
    }
    if ($ctx.EnvFile -and -not (Test-Path $ctx.EnvFile)) {
        Write-Status -Stage 'error' -ErrorMsg ".env not found at $($ctx.EnvFile); HELPER_TOKEN / image tag would not interpolate. Re-run install.ps1 -AddHelper."
        return
    }

    # Build the shared compose args: project + every -f + optional --env-file.
    $base = @('compose', '--project-name', $ctx.Project)
    foreach ($f in $ctx.ComposeFiles) { $base += @('-f', $f) }
    if ($ctx.EnvFile) { $base += @('--env-file', $ctx.EnvFile) }

    $preId = (& $docker inspect --format '{{.Id}}' $AppContainer 2>$null)

    # pull -- non-fatal on its own: a transient registry blip shouldn't brick the
    # update. Truthfulness is enforced by the post-recreate check below.
    $pullExit = Invoke-DockerStep -Docker $docker -DockerArgs ($base + @('pull', $AppService)) -WorkingDir $ctx.WorkingDir -TimeoutSec $StepTimeoutSec
    $pullOk = ($pullExit -eq 0)
    if (-not $pullOk) { Write-AppLog "docker compose pull exit $pullExit (continuing; will use cached image if present)" }

    Write-Status -Stage 'restarting'
    $upExit = Invoke-DockerStep -Docker $docker -DockerArgs ($base + @('up', '-d', $AppService)) -WorkingDir $ctx.WorkingDir -TimeoutSec $StepTimeoutSec
    if ($upExit -ne 0) {
        Write-Status -Stage 'error' -ErrorMsg "docker compose up -d failed (exit $upExit). See last-apply.log."
        return
    }

    # Truthful result: compare the app container id before/after. Unchanged means
    # nothing was recreated -- report honestly instead of a false "done".
    $postId = (& $docker inspect --format '{{.Id}}' $AppContainer 2>$null)
    if ($preId -and $postId -and $preId -eq $postId) {
        if (-not $pullOk) {
            Write-Status -Stage 'error' -ErrorMsg 'Could not pull the target image and the container was not recreated -- version unchanged. Check the host network / registry access.'
            return
        }
        Write-Status -Stage 'done' -Detail 'Already current -- no new image to apply (container not recreated).'
        return
    }

    Write-Status -Stage 'done'
    Write-AppLog "apply complete: container recreated ($preId -> $postId)"
}
catch {
    Write-Status -Stage 'error' -ErrorMsg ("Apply worker exception: " + $_.Exception.Message)
}
finally {
    if (-not $script:Terminal) {
        Write-Status -Stage 'error' -ErrorMsg 'Apply worker exited unexpectedly without completing -- see last-apply.log.'
    }
}
