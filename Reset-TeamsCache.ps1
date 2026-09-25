<#
================================================================================
  RMM Script Library - Reset-TeamsCache
================================================================================
  PURPOSE : The standard fix for Teams blank screen / stuck loading / stale
            data. Clears the new-Teams cache (and dead classic-Teams
            remnants) for the LOGGED-IN user.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : *** USER (Current User) - NOT System ***
                    The cache lives in the user profile; running as System
                    is blocked by a guard below.
    - Max run time: 5 minutes

  MODES   : (no switch)  REPORT-ONLY - shows cache sizes and what -Fix would do.
            -Fix         closes Teams, clears the cache, reports MB freed.
                         User reopens Teams afterward and may need to sign in.

  EXIT CODES:  0 = OK   1 = needs attention   2 = script/context error

  VERSION : 0.1-DEV (2026-07-21)
================================================================================
#>
param([switch]$Fix)

$ScriptName    = 'Reset-TeamsCache'
$ScriptVersion = '0.1-DEV'
$ErrorActionPreference = 'Continue'

$script:OutBuf = New-Object System.Collections.Generic.List[string]
$script:Issues = New-Object System.Collections.Generic.List[string]

function W    { param([string]$Text = '') $script:OutBuf.Add($Text) | Out-Null; Write-Output $Text }
function Flag { param([string]$Text) $script:Issues.Add($Text) | Out-Null }
function Sect { param([string]$Title) W ''; W (("---- {0} " -f $Title).PadRight(64, '-')) }

function Save-Log {
    try {
        $dir = 'C:\ProgramData\RMMScripts\Logs'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $file = Join-Path $dir ("{0}-{1}.log" -f $ScriptName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $script:OutBuf | Set-Content -Path $file -Encoding UTF8
    } catch { }
}

function Finish {
    W ''
    W ('=' * 64)
    if ($script:Issues.Count -gt 0) {
        W 'ISSUES FOUND:'
        foreach ($i in $script:Issues) { W ("  ! {0}" -f $i) }
        W ''
        W ("RESULT: NEEDS-ATTENTION ({0} issue(s))" -f $script:Issues.Count)
        Save-Log
        exit 1
    } else {
        W 'No issues flagged.'
        W ''
        W 'RESULT: OK'
        Save-Log
        exit 0
    }
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $null }
    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [math]::Round($sum / 1MB)
    } catch { return $null }
}

try {
    W ('=' * 64)
    W (" {0}  v{1}   mode: {2}" -f $ScriptName, $ScriptVersion, $(if ($Fix) { 'FIX' } else { 'REPORT-ONLY (run with -Fix to apply)' }))
    W ('=' * 64)
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f $ident.Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # ---- Context guard: this must run in the USER's session, not SYSTEM ----
    if ($ident.User.Value -eq 'S-1-5-18') {
        W ''
        W 'WRONG RUN-AS CONTEXT.'
        W 'This script clears cache inside the logged-in user profile.'
        W 'In the RMM, re-run it with  Run As: Current User  (not System).'
        W ''
        W 'RESULT: SCRIPT-ERROR (wrong context - nothing was changed)'
        Save-Log
        exit 2
    }

    $pkgRoot   = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe'
    $cacheDir  = Join-Path $pkgRoot 'LocalCache\Microsoft\MSTeams'
    $classic   = Join-Path $env:APPDATA 'Microsoft\Teams'

    # ---------------- Current state ----------------
    Sect 'Current state'
    $teamsProcs = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue)
    W ("Teams running       : {0}{1}" -f $(if ($teamsProcs.Count) { 'yes' } else { 'no' }), $(if ($teamsProcs.Count) { " ({0} process(es))" -f $teamsProcs.Count } else { '' }))
    if (-not (Test-Path $pkgRoot)) {
        W 'New Teams package folder not found for this user.'
        Flag 'New Teams is not installed/provisioned for this user - nothing to reset; check Teams installation instead'
        Finish
    }
    $cacheMB = Get-FolderSizeMB $cacheDir
    W ("Teams cache         : {0}" -f $(if ($null -ne $cacheMB) { "{0} MB  ({1})" -f $cacheMB, $cacheDir } else { "not found ($cacheDir)" }))
    $classicMB = $null
    if (Test-Path $classic) {
        $classicMB = Get-FolderSizeMB $classic
        W ("Classic Teams (dead): {0} MB  ({1})" -f $classicMB, $classic)
    } else {
        W 'Classic Teams (dead): no remnants'
    }

    # ---------------- Report-only stops here ----------------
    if (-not $Fix) {
        Sect 'Planned actions (re-run with -Fix to apply)'
        W '  1. Close Teams (ms-teams processes)'
        if ($null -ne $cacheMB) { W ("  2. Delete contents of LocalCache\Microsoft\MSTeams  (~{0} MB)" -f $cacheMB) }
        if ($null -ne $classicMB) { W ("  3. Delete dead classic-Teams folder                 (~{0} MB)" -f $classicMB) }
        W '  User then reopens Teams (fresh cache rebuilds; may need to sign in).'
        Finish
    }

    # ---------------- Fix ----------------
    Sect 'Applying fix'
    if ($teamsProcs.Count -gt 0) {
        W 'Closing Teams...'
        Stop-Process -Name 'ms-teams' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $still = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue)
        if ($still.Count -gt 0) {
            Flag 'Could not close all Teams processes - cache clear may be incomplete; try again or reboot'
        } else {
            W 'Teams closed.'
        }
    }

    $freed = 0
    if ((Test-Path $cacheDir) -and $null -ne $cacheMB) {
        Get-ChildItem -Path $cacheDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        $after = Get-FolderSizeMB $cacheDir
        if ($null -eq $after) { $after = 0 }
        $freed += ($cacheMB - $after)
        W ("Teams cache cleared : {0} MB freed" -f ($cacheMB - $after))
        if ($after -gt 50) { Flag ("~{0} MB of cache could not be deleted (files in use) - close Teams fully or reboot, then re-run" -f $after) }
    }
    if ($null -ne $classicMB -and (Test-Path $classic)) {
        Remove-Item $classic -Recurse -Force -ErrorAction SilentlyContinue
        $afterClassic = Get-FolderSizeMB $classic
        if ($null -eq $afterClassic) { $afterClassic = 0 }
        $freed += ($classicMB - $afterClassic)
        W ("Classic remnants    : {0} MB freed" -f ($classicMB - $afterClassic))
    }

    Sect 'Done'
    W ("Total freed         : {0} MB" -f $freed)
    W 'Tell the user to reopen Teams. First launch rebuilds the cache'
    W '(takes a minute) and may ask them to sign in again.'

    Finish
}
catch {
    W ''
    W ("SCRIPT ERROR: {0}" -f $_.Exception.Message)
    W ("  at: {0}" -f $_.InvocationInfo.PositionMessage)
    W 'RESULT: SCRIPT-ERROR'
    Save-Log
    exit 2
}
