<#
================================================================================
  RMM Script Library - Get-DockDisplayHealth
================================================================================
  PURPOSE : Dock / external display triage. Read-only.
            Dock tickets usually masquerade as "driver problems". This script
            sorts the real cause remotely:
              - Is the USB-C PD controller (UCSI) healthy, or has it crashed?
                (common failure mode: UCSI crash -> dock drops to
                 USB3-only, displays dead; fix = full power-drain EC reset)
              - Is the dock linked in USB4/Thunderbolt mode or stuck in USB3?
              - What monitors does Windows actually see right now?
              - GPU adapters + driver state.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 5 minutes

  EXIT CODES:  0 = healthy   1 = issues flagged   2 = script error

  VERSION : 0.1-DEV (2026-07-21)
================================================================================
#>

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ScriptName    = 'Get-DockDisplayHealth'
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

try {
    W ('=' * 64)
    W (" {0}  v{1}" -f $ScriptName, $ScriptVersion)
    W ('=' * 64)
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    $pnpAll     = @(Get-PnpDevice -ErrorAction SilentlyContinue)
    $pnpPresent = @($pnpAll | Where-Object Status -ne 'Unknown' | Where-Object { $_.Present })

    # ---------------- GPUs ----------------
    Sect 'GPU adapters'
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($g in $gpus) {
        $drvDate = ''
        if ($g.DriverDate) { $drvDate = $g.DriverDate.ToString('yyyy-MM-dd') }
        W ("  {0}" -f $g.Name)
        W ("    driver {0}  ({1})  status: {2}" -f $g.DriverVersion, $drvDate, $g.Status)
        if ($g.Status -ne 'OK' -or ($g.ConfigManagerErrorCode -and $g.ConfigManagerErrorCode -ne 0)) {
            Flag ("GPU '{0}' reports status {1} (CM error {2}) - driver problem" -f $g.Name, $g.Status, $g.ConfigManagerErrorCode)
        }
    }

    # ---------------- Monitors ----------------
    Sect 'Monitors Windows can see right now'
    $monNames = @()
    try {
        $wmiMon = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | Where-Object Active)
        foreach ($m in $wmiMon) {
            $name = ''
            if ($m.UserFriendlyName) { $name = ([char[]]($m.UserFriendlyName | Where-Object { $_ -gt 0 })) -join '' }
            if (-not $name) { $name = 'unknown model' }
            $monNames += $name
        }
    } catch {
        # fall back to PnP monitor class (root\wmi can be restricted)
        $monNames = @($pnpPresent | Where-Object Class -eq 'Monitor' | ForEach-Object { $_.FriendlyName })
    }
    W ("  Count: {0}" -f $monNames.Count)
    foreach ($n in $monNames) { W ("    {0}" -f $n) }
    W '  (internal laptop panel counts as 1 - compare against what the user expects)'

    # ---------------- USB4 / Thunderbolt link state ----------------
    Sect 'USB4 / Thunderbolt'
    $usb4Present = @($pnpPresent | Where-Object { $_.InstanceId -like 'USB4\*' })
    $usb4Ghost   = @($pnpAll | Where-Object { $_.InstanceId -like 'USB4\*' -and -not $_.Present })
    # Host-side plumbing is named differently across builds: "USB4(TM) Host
    # Router", "USB4 Root Router", plus the virtual power device. Anything
    # else under USB4\ is a real downstream device (the dock).
    $infraMatch  = { $_.InstanceId -match 'ROOT_DEVICE_ROUTER|VIRTUAL_POWER_PDO' -or $_.FriendlyName -match 'Host Router|Root Router|Virtual power' }
    $hostRouters = @($usb4Present | Where-Object $infraMatch)
    $devRouters  = @($usb4Present | Where-Object { -not ($_.InstanceId -match 'ROOT_DEVICE_ROUTER|VIRTUAL_POWER_PDO' -or $_.FriendlyName -match 'Host Router|Root Router|Virtual power') })
    W ("  Host-side (infrastructure): {0}" -f $hostRouters.Count)
    foreach ($r in $hostRouters) { W ("    {0}" -f $r.FriendlyName) }
    W ("  Device routers (dock): {0}" -f $devRouters.Count)
    foreach ($r in $devRouters) {
        W ("    {0}  [{1}]" -f $r.FriendlyName, $r.InstanceId)
        if ($r.Status -ne 'OK') { Flag ("USB4 router '{0}' status {1}" -f $r.FriendlyName, $r.Status) }
    }
    $ghostDocks = @($usb4Ghost | Where-Object { -not ($_.InstanceId -match 'ROOT_DEVICE_ROUTER|VIRTUAL_POWER_PDO' -or $_.FriendlyName -match 'Host Router|Root Router|Virtual power') } | Select-Object -ExpandProperty FriendlyName -Unique)
    if ($ghostDocks.Count -gt 0) {
        W ("  Previously seen in USB4 mode (not connected now): {0}" -f ($ghostDocks -join '; '))
    }

    # ---------------- USB hubs (dock detection) ----------------
    Sect 'External USB hubs'
    $hubs = @($pnpPresent | Where-Object { $_.Class -eq 'USB' -and $_.FriendlyName -match 'hub' -and $_.InstanceId -notmatch '^USB\\ROOT' })
    W ("  Non-root USB hubs: {0}{1}" -f $hubs.Count, $(if ($hubs.Count -gt 8) { ' (showing first 8)' } else { '' }))
    $vendorIds = @()
    foreach ($h in $hubs) {
        if ($h.InstanceId -match 'VID_([0-9A-F]{4})') { $vendorIds += $Matches[1] }
    }
    foreach ($h in $hubs | Select-Object -First 8) {
        W ("    {0}" -f $h.FriendlyName)
    }
    $calDigit = ($vendorIds -contains '2188')
    if ($calDigit) { W '  CalDigit dock hardware detected (VID_2188).' }
    $displayLink = @($pnpPresent | Where-Object { $_.FriendlyName -match 'DisplayLink' }).Count -gt 0
    if (-not $displayLink) { $displayLink = $null -ne (Get-Service -Name 'DisplayLinkService' -ErrorAction SilentlyContinue) }
    W ("  DisplayLink (USB graphics) present: {0}" -f $(if ($displayLink) { 'yes' } else { 'no' }))

    # The signature failure: dock USB hubs enumerate but no USB4 device router
    # means the link fell back to USB3-only - on a TB/USB4 dock the display
    # outputs are dead in this state.
    if ($hubs.Count -gt 0 -and $devRouters.Count -eq 0 -and -not $displayLink) {
        if ($ghostDocks.Count -gt 0 -or $calDigit) {
            Flag 'Dock USB is up but NO USB4 router is present - dock has fallen back to USB3-only mode (displays dead). Known fix: full power-drain EC reset of the laptop + dock power cycle; then check dock firmware.'
        } else {
            W '  Note: USB hubs present without a USB4 router - fine for a plain USB3 hub/dock without video.'
        }
    }

    # ---------------- USB-C PD controller (UCSI) health ----------------
    Sect 'USB-C PD controller (UCSI)'
    $ucsi = @($pnpAll | Where-Object { $_.InstanceId -like 'ACPI\USBC000*' -or $_.FriendlyName -match 'UCSI' })
    if ($ucsi.Count -eq 0) {
        W '  No UCSI device found (machine may not expose one).'
    }
    foreach ($u in $ucsi) {
        W ("  {0}  status: {1}  problem: {2}" -f $u.FriendlyName, $u.Status, $u.Problem)
        if ($u.Status -ne 'OK') {
            Flag ("UCSI PD controller '{0}' status {1} ({2}) - USB-C/dock ports degraded. Known fix: full power-drain EC reset (shutdown, unplug charger, hold power 30-60s)" -f $u.FriendlyName, $u.Status, $u.Problem)
        }
    }
    $ucsiErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-USB-UCMUCSICX/Operational'; Level = 1, 2; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 50 -ErrorAction SilentlyContinue)
    W ("  UCSI error events (14d): {0}" -f $ucsiErr.Count)
    if ($ucsiErr.Count -gt 0) {
        $latest = $ucsiErr | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $msg = [string]$latest.Message
        if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
        W ("    latest {0}: {1}" -f $latest.TimeCreated.ToString('MM/dd HH:mm'), $msg)
        $recent = @($ucsiErr | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-3) })
        if ($recent.Count -gt 0) {
            Flag ("{0} UCSI (USB-C PD) error(s) in the last 3 days - PD controller instability; EC reset likely needed" -f $recent.Count)
        }
    }

    # ---------------- Power source ----------------
    Sect 'Power'
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        $onAc = ($bat.BatteryStatus -ne 1)
        W ("  On AC power: {0} (charge {1}%)" -f $(if ($onAc) { 'yes' } else { 'NO - running on battery' }), $bat.EstimatedChargeRemaining)
        if (-not $onAc -and ($hubs.Count -gt 0 -or $devRouters.Count -gt 0)) {
            W '  Note: dock devices present but laptop not charging - check dock power/cable seating.'
        }
    } else {
        W '  No battery (desktop).'
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
