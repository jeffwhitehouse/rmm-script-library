<#
================================================================================
  RMM Script Library - Get-TriageSnapshot
================================================================================
  PURPOSE : Run-first triage on any ticket. Read-only. Answers "is this
            machine actually unhealthy" before anyone remotes in:
            uptime / pending reboot / disk / RAM+CPU hogs / battery wear /
            recent BSODs and app crashes / Windows Update recency /
            Entra join state / basic network reachability.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 5 minutes

  EXIT CODES:  0 = healthy (RESULT: OK)
               1 = issues flagged (RESULT: NEEDS-ATTENTION, see list)
               2 = script error (RESULT: SCRIPT-ERROR)

  OUTPUT  : Read the last block first - ISSUES FOUND + RESULT line.
  LOG     : Copy saved to C:\ProgramData\RMMScripts\Logs\ (best effort).

  VERSION : 0.1-DEV (2026-07-21)  - initial build
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

$ScriptName    = 'Get-TriageSnapshot'
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

    # ---------------- OS / uptime / pending reboot ----------------
    Sect 'System'
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = 'unknown'
    if ($cv) { $build = ("{0} (build {1}.{2})" -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR) }
    W ("OS            : {0}  {1}" -f $os.Caption, $build)

    $uptime = (Get-Date) - $os.LastBootUpTime
    W ("Last boot     : {0}" -f $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))
    W ("Uptime        : {0} day(s) {1} hour(s)" -f [int]$uptime.Days, $uptime.Hours)
    if ($uptime.TotalDays -gt 14) { Flag ("Uptime is {0} days - recommend reboot before further troubleshooting" -f [int]$uptime.TotalDays) }

    $rebootCbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $rebootWu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pendReboot = ($rebootCbs -or $rebootWu)
    W ("Reboot pending: {0}" -f $(if ($pendReboot) { 'YES (CBS={0} WU={1})' -f $rebootCbs, $rebootWu } else { 'no' }))
    if ($pendReboot) { Flag 'A reboot is pending (servicing/Windows Update)' }

    # ---------------- Disk ----------------
    Sect 'Disk'
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3'
    foreach ($d in $disks) {
        if ($d.Size -gt 0) {
            $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
            $sizeGB = [math]::Round($d.Size / 1GB, 1)
            $pct    = [math]::Round(($d.FreeSpace / $d.Size) * 100)
            W ("Drive {0}      : {1} GB free of {2} GB ({3}% free)" -f $d.DeviceID, $freeGB, $sizeGB, $pct)
            if ($pct -lt 10 -or $freeGB -lt 15) { Flag ("Drive {0} is low on space ({1} GB / {2}% free)" -f $d.DeviceID, $freeGB, $pct) }
        }
    }

    # ---------------- Memory ----------------
    Sect 'Memory'
    $totMB  = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB)
    $usedPct = [math]::Round((($totMB - $freeMB) / $totMB) * 100)
    W ("RAM           : {0} MB used of {1} MB ({2}% in use)" -f ($totMB - $freeMB), $totMB, $usedPct)
    if ($usedPct -gt 90) { Flag ("Memory pressure: {0}% of RAM in use" -f $usedPct) }

    W 'Top RAM consumers (working set, grouped by process name):'
    Get-Process |
        Group-Object Name |
        ForEach-Object {
            $sum = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
            New-Object psobject -Property @{ Name = $_.Name; MB = [math]::Round($sum / 1MB); N = $_.Count }
        } |
        Sort-Object MB -Descending |
        Select-Object -First 5 |
        ForEach-Object { W ("  {0,-28} {1,7} MB  (x{2})" -f $_.Name, $_.MB, $_.N) }

    # ---------------- CPU (2-second sample) ----------------
    Sect 'CPU'
    $cores = [Environment]::ProcessorCount
    $s1 = @{}
    Get-Process | ForEach-Object { try { $s1[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch { } }
    Start-Sleep -Seconds 2
    $deltas = @{}
    Get-Process | ForEach-Object {
        try {
            if ($s1.ContainsKey($_.Id)) {
                $d = $_.TotalProcessorTime.TotalMilliseconds - $s1[$_.Id]
                if ($d -gt 0) {
                    if ($deltas.ContainsKey($_.Name)) { $deltas[$_.Name] += $d } else { $deltas[$_.Name] = $d }
                }
            }
        } catch { }
    }
    $top = $deltas.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    W ("Logical cores : {0}" -f $cores)
    W 'Top CPU consumers over a 2s sample:'
    $printed = 0
    foreach ($t in $top) {
        $pct = [math]::Round(($t.Value / 2000 / $cores) * 100, 1)
        if ($pct -ge 0.5) { W ("  {0,-28} {1,5}%" -f $t.Key, $pct); $printed++ }
    }
    if ($printed -eq 0) { W '  (idle - no process above 0.5% of total CPU)' }
    $busiest = $deltas.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if ($busiest -and (($busiest.Value / 2000 / $cores) * 100) -gt 60) {
        Flag ("Process '{0}' is using most of the CPU right now" -f $busiest.Key)
    }

    # ---------------- Battery ----------------
    Sect 'Battery'
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat) {
        $statusMap = @{ 1 = 'Discharging'; 2 = 'On AC'; 3 = 'Fully charged'; 4 = 'Low'; 5 = 'Critical'; 6 = 'Charging'; 7 = 'Charging (high)'; 8 = 'Charging (low)'; 9 = 'Charging (critical)'; 10 = 'Unknown'; 11 = 'Partially charged' }
        $bs = $statusMap[[int]$bat.BatteryStatus]
        if (-not $bs) { $bs = "code $($bat.BatteryStatus)" }
        W ("Charge        : {0}%  ({1})" -f $bat.EstimatedChargeRemaining, $bs)
        try {
            $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Measure-Object FullChargedCapacity -Sum).Sum
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Measure-Object DesignedCapacity -Sum).Sum
            if ($design -gt 0 -and $full -gt 0) {
                $wear = 100 - [math]::Round(($full / $design) * 100)
                W ("Battery wear  : {0}% (design {1} mWh, full-charge {2} mWh)" -f $wear, $design, $full)
                if ($wear -gt 40) { Flag ("Battery has lost {0}% of design capacity - consider replacement" -f $wear) }
            }
        } catch {
            W 'Battery wear  : n/a (WMI battery classes not readable in this context)'
        }
    } else {
        W 'No battery (desktop or VM).'
    }

    # ---------------- Stability: BSODs and app crashes (7 days) ----------------
    Sect 'Stability (last 7 days)'
    $since = (Get-Date).AddDays(-7)
    $bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001; StartTime = $since } -ErrorAction SilentlyContinue |
              Where-Object { $_.ProviderName -in @('Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-WER-SystemErrorReporting') })
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
    W ("Unexpected shutdowns / bugchecks : {0}" -f $bsod.Count)
    W ("WHEA hardware errors             : {0}" -f $whea.Count)
    if ($bsod.Count -gt 0) {
        $last = $bsod | Sort-Object TimeCreated -Descending | Select-Object -First 1
        Flag ("{0} unexpected shutdown/bugcheck event(s) in 7 days (latest {1})" -f $bsod.Count, $last.TimeCreated.ToString('MM/dd HH:mm'))
    }
    if ($whea.Count -gt 0) { Flag ("{0} WHEA hardware error event(s) in 7 days" -f $whea.Count) }

    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = $since } -ErrorAction SilentlyContinue)
    if ($crashes.Count -gt 0) {
        W 'App crashes/hangs by executable:'
        $byApp = $crashes | ForEach-Object {
            $app = 'unknown'
            try { if ($_.Properties.Count -gt 0 -and $_.Properties[0].Value) { $app = [string]$_.Properties[0].Value } } catch { }
            $app
        } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5
        foreach ($g in $byApp) {
            W ("  {0,-32} x{1}" -f $g.Name, $g.Count)
            if ($g.Count -ge 3) { Flag ("'{0}' crashed/hung {1} times in 7 days" -f $g.Name, $g.Count) }
        }
    } else {
        W 'App crashes/hangs by executable: none'
    }

    # ---------------- Windows Update recency + activation ----------------
    Sect 'Windows Update / activation'
    $wuTime = $null
    try {
        $wuKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install' -ErrorAction Stop
        $wuTime = [datetime]::Parse($wuKey.LastSuccessTime, [Globalization.CultureInfo]::InvariantCulture)
    } catch { }
    $qfe = Get-CimInstance Win32_QuickFixEngineering -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($wuTime) { W ("Last WU success (registry) : {0}" -f $wuTime.ToString('yyyy-MM-dd HH:mm')) } else { W 'Last WU success (registry) : n/a (key absent on newer builds - normal)' }
    if ($qfe)    { W ("Latest hotfix installed    : {0} on {1}" -f $qfe.HotFixID, $qfe.InstalledOn.ToString('yyyy-MM-dd')) }
    $newest = $null
    if ($wuTime) { $newest = $wuTime }
    if ($qfe -and $qfe.InstalledOn -and (-not $newest -or $qfe.InstalledOn -gt $newest)) { $newest = $qfe.InstalledOn }
    if ($newest -and ((Get-Date) - $newest).TotalDays -gt 45) {
        Flag ("No successful Windows Update activity in {0} days" -f [int]((Get-Date) - $newest).TotalDays)
    }

    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lic) {
        $licTxt = if ($lic.LicenseStatus -eq 1) { 'Licensed' } else { "NOT licensed (status $($lic.LicenseStatus))" }
        W ("Windows activation         : {0}" -f $licTxt)
        if ($lic.LicenseStatus -ne 1) { Flag 'Windows is not activated' }
    } else {
        W 'Windows activation         : n/a'
    }

    # ---------------- Entra join ----------------
    Sect 'Entra / domain join'
    try {
        $ds = & "$env:WINDIR\System32\dsregcmd.exe" /status 2>$null
        foreach ($k in 'AzureAdJoined', 'EnterpriseJoined', 'DomainJoined', 'DomainName', 'TenantName', 'DeviceId') {
            $line = $ds | Where-Object { $_ -match ("^\s*{0}\s*:" -f $k) } | Select-Object -First 1
            if ($line) { W ($line.Trim()) }
        }
        $aadJoined = $ds | Where-Object { $_ -match '^\s*AzureAdJoined\s*:\s*YES' }
        if (-not $aadJoined) { Flag 'Device does not report AzureAdJoined: YES' }
    } catch {
        W 'dsregcmd not available.'
    }

    # ---------------- Network quick check ----------------
    Sect 'Network (quick)'
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($route) {
        $ifIdx = $route.InterfaceIndex
        $ad = Get-NetAdapter -InterfaceIndex $ifIdx -ErrorAction SilentlyContinue
        $ip = Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ad) { W ("Active adapter: {0} ({1}, {2})" -f $ad.Name, $ad.InterfaceDescription, $ad.LinkSpeed) }
        if ($ip) { W ("IPv4 / GW     : {0}  ->  {1}" -f $ip.IPAddress, $route.NextHop) }
        $ping = New-Object System.Net.NetworkInformation.Ping
        foreach ($target in @(@('Gateway', $route.NextHop), @('Internet (8.8.8.8)', '8.8.8.8'))) {
            try {
                $r = $ping.Send($target[1], 1500)
                if ($r.Status -eq 'Success') { W ("Ping {0,-18}: {1} ms" -f $target[0], $r.RoundtripTime) }
                else { W ("Ping {0,-18}: {1}" -f $target[0], $r.Status); Flag ("Ping to {0} failed ({1})" -f $target[0], $r.Status) }
            } catch { W ("Ping {0,-18}: error" -f $target[0]); Flag ("Ping to {0} failed" -f $target[0]) }
        }
    } else {
        W 'No default route - machine has no path to the internet.'
        Flag 'No default route (no active network connection)'
    }
    W 'For full network/VPN triage run Test-NetworkHealth.'

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
