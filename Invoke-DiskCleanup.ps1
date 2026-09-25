<#
================================================================================
  RMM Script Library - Invoke-DiskCleanup
================================================================================
  PURPOSE : Reclaim disk space for low-disk / slowness tickets. Reports what
            is eating space, and with -Fix clears the safe stuff:
            temp files (>24h old), Windows Update download cache,
            Delivery Optimization cache, old crash dumps.
            NEVER touches: user files, recycle bin, Windows.old (reported
            with sizes so a human can decide).

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 10 minutes

  MODES   : (no switch)  REPORT-ONLY - sizes + what -Fix would clear.
            -Fix         apply the safe cleanups, report GB freed.

  EXIT CODES:  0 = OK   1 = needs attention   2 = script/context error

  VERSION : 0.1-DEV (2026-07-21)
================================================================================
#>
param([switch]$Fix)

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        $extra = @(); if ($Fix) { $extra += '-Fix' }
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath @extra
        exit $LASTEXITCODE
    }
}

$ScriptName    = 'Invoke-DiskCleanup'
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

function Get-FreeGB {
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($c) { return [math]::Round($c.FreeSpace / 1GB, 1) }
    return $null
}

try {
    W ('=' * 64)
    W (" {0}  v{1}   mode: {2}" -f $ScriptName, $ScriptVersion, $(if ($Fix) { 'FIX' } else { 'REPORT-ONLY (run with -Fix to apply)' }))
    W ('=' * 64)
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f $ident.Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # ---- Context guard: -Fix needs SYSTEM/admin ----
    $isAdmin = ([Security.Principal.WindowsPrincipal]$ident).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Fix -and -not $isAdmin) {
        W ''
        W 'WRONG RUN-AS CONTEXT.'
        W 'Cleanup needs System rights (machine temp, WU cache). In the RMM,'
        W 're-run it with  Run As: System  (the default).'
        W ''
        W 'RESULT: SCRIPT-ERROR (wrong context - nothing was changed)'
        Save-Log
        exit 2
    }
    if (-not $isAdmin) {
        W ' NOTE: running unelevated - sizes below are best-effort (some paths unreadable).'
    }

    $freeBefore = Get-FreeGB
    W (" C: free    : {0} GB" -f $freeBefore)

    # ---------------- Survey ----------------
    Sect 'What is using space (cleanable by -Fix)'
    $winTemp = "$env:WINDIR\Temp"
    $wuCache = "$env:WINDIR\SoftwareDistribution\Download"
    $doCache = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    $liveKernel = "$env:WINDIR\LiveKernelReports"
    $miniDump = "$env:WINDIR\Minidump"
    $memDump = "$env:WINDIR\MEMORY.DMP"

    $targets = @()
    $t = Get-FolderSizeMB $winTemp
    if ($null -ne $t) { W ("  Windows temp                : {0,8} MB" -f $t); $targets += , @('wintemp', $t) }
    $userTempTotal = 0
    $profiles = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') })
    foreach ($p in $profiles) {
        $ut = Get-FolderSizeMB (Join-Path $p.FullName 'AppData\Local\Temp')
        if ($null -ne $ut) { $userTempTotal += $ut }
    }
    W ("  User temp (all profiles)    : {0,8} MB" -f $userTempTotal)
    $wu = Get-FolderSizeMB $wuCache
    if ($null -ne $wu) { W ("  Windows Update downloads    : {0,8} MB" -f $wu) }
    $do = Get-FolderSizeMB $doCache
    if ($null -ne $do) { W ("  Delivery Optimization cache : {0,8} MB" -f $do) } else { W '  Delivery Optimization cache : n/a (not readable in this context)' }
    $dumpMB = 0
    foreach ($dPath in @($liveKernel, $miniDump)) {
        $s = Get-FolderSizeMB $dPath
        if ($null -ne $s) { $dumpMB += $s }
    }
    $memDumpItem = Get-Item $memDump -Force -ErrorAction SilentlyContinue
    if ($memDumpItem) { $dumpMB += [math]::Round($memDumpItem.Length / 1MB) }
    W ("  Crash dumps (>7d old only)  : {0,8} MB total on disk" -f $dumpMB)

    Sect 'Reported only - NEVER auto-deleted'
    foreach ($drv in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $rb = Get-FolderSizeMB ("{0}\`$Recycle.Bin" -f $drv.DeviceID)
        if ($null -ne $rb -and $rb -gt 0) { W ("  Recycle bin {0}              : {1,8} MB  (user data - empty via user, not script)" -f $drv.DeviceID, $rb) }
    }
    if (Test-Path 'C:\Windows.old' -ErrorAction SilentlyContinue) {
        $wo = Get-FolderSizeMB 'C:\Windows.old'
        W ("  C:\Windows.old              : {0,8} MB  (removable via Storage Sense/Disk Cleanup if rollback not needed)" -f $wo)
        # Only worth an alert when space is actually tight
        if ($null -ne $freeBefore -and $freeBefore -lt 100) {
            Flag ("Windows.old is holding ~{0} GB - remove via Disk Cleanup if the upgrade is confirmed good" -f [math]::Round($wo / 1024, 1))
        }
    }
    $teamsHint = 0
    foreach ($p in $profiles) {
        $tc = Get-FolderSizeMB (Join-Path $p.FullName 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams')
        if ($null -ne $tc) { $teamsHint += $tc }
    }
    if ($teamsHint -gt 1024) { W ("  Teams caches (all users)    : {0,8} MB  (use Reset-TeamsCache as the user)" -f $teamsHint) }

    # ---------------- Report-only stops here ----------------
    if (-not $Fix) {
        Sect 'Planned actions (re-run with -Fix to apply)'
        W '  1. Delete temp files older than 24h (Windows temp + every user temp)'
        W '  2. Stop wuauserv/bits -> clear WU download cache -> restart services'
        W '  3. Clear Delivery Optimization cache'
        W '  4. Delete crash dumps older than 7 days'
        if ($freeBefore -lt 15) { Flag ("C: has only {0} GB free - run with -Fix" -f $freeBefore) }
        Finish
    }

    # ---------------- Fix ----------------
    $cutoff = (Get-Date).AddHours(-24)
    Sect 'Applying cleanup'

    W 'Clearing temp files older than 24h...'
    $tempDirs = @($winTemp)
    foreach ($p in $profiles) { $tempDirs += (Join-Path $p.FullName 'AppData\Local\Temp') }
    foreach ($td in $tempDirs) {
        if (Test-Path $td) {
            Get-ChildItem $td -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            # sweep now-empty subfolders (best effort)
            Get-ChildItem $td -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { @(Get-ChildItem $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue).Count -eq 0 } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    W '  done.'

    W 'Clearing Windows Update download cache...'
    $svcStopped = $false
    try {
        Stop-Service wuauserv, bits -Force -ErrorAction Stop
        $svcStopped = $true
    } catch { W '  could not stop wuauserv/bits - skipping WU cache clear' }
    if ($svcStopped) {
        Get-ChildItem $wuCache -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
        $wuSvc = Get-Service wuauserv -ErrorAction SilentlyContinue
        W ("  done (wuauserv now {0})." -f $(if ($wuSvc) { $wuSvc.Status } else { 'unknown' }))
        if ($wuSvc -and $wuSvc.Status -ne 'Running') { Flag 'wuauserv did not restart after cache clear - start it or reboot' }
    }

    W 'Clearing Delivery Optimization cache...'
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        W '  done.'
    } catch {
        W ("  skipped ({0})" -f $_.Exception.Message)
    }

    W 'Deleting crash dumps older than 7 days...'
    $dumpCutoff = (Get-Date).AddDays(-7)
    foreach ($dPath in @($liveKernel, $miniDump)) {
        if (Test-Path $dPath) {
            Get-ChildItem $dPath -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $dumpCutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    $memDumpFix = Get-Item $memDump -Force -ErrorAction SilentlyContinue
    if ($memDumpFix -and $memDumpFix.LastWriteTime -lt $dumpCutoff) {
        Remove-Item $memDump -Force -ErrorAction SilentlyContinue
    }
    W '  done.'

    Sect 'Outcome'
    $freeAfter = Get-FreeGB
    W ("C: free before : {0} GB" -f $freeBefore)
    W ("C: free after  : {0} GB" -f $freeAfter)
    if ($null -ne $freeBefore -and $null -ne $freeAfter) {
        W ("Reclaimed      : {0} GB" -f ([math]::Round($freeAfter - $freeBefore, 1)))
    }
    if ($null -ne $freeAfter -and $freeAfter -lt 15) {
        Flag ("C: still low after cleanup ({0} GB free) - check recycle bin/Windows.old above, or the disk is genuinely full of user/app data" -f $freeAfter)
    }

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
