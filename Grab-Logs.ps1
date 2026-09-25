<#
================================================================================
  RMM Script Library - Grab-Logs        RMM name: "Grab Logs"
================================================================================
  PURPOSE : One-shot support bundle for ANY end-user complaint ("slow",
            "freezes", "Outlook / Teams / browser hangs", "keeps dropping").
            READ-ONLY. Collects what a tech needs to troubleshoot
            without remoting in:
              - hardware, OS, uptime, pending reboot, power mode, battery
              - RAM / commit / CPU pressure and the top consumers
              - GPU + display driver, GPU resets, disk health + wear,
                devices with error codes
              - stability history: app hangs + crashes (with faulting module),
                WER buckets, BSODs, live kernel dumps, low-memory events,
                CPU throttling, service crashes, boot/desktop degradation
              - browsers (Edge / Chrome / Brave / Opera / Firefox): version,
                default browser, profiles, clean-exit state, extensions, GPU
                acceleration flag, crash dumps, Outlook-web site data,
                Intune/GPO browser policies; WebView2 runtime
              - Outlook (classic + new), Teams, OneDrive state
              - network: adapter + driver, Wi-Fi quality and drops, latency,
                DNS, TCP 443, HTTPS time-to-first-byte, TLS inspection check,
                proxy, VPN / SASE agents
              - security agents, recent installs, startup items, WU history
              - digest of recent Error/Critical events (noise filtered)

  HOW TECHS USE IT:
    1. RMM > device > Run Script > "Grab Logs"  (Run as System).
    2. When it finishes open the output, select all, copy.
    3. Paste it into the ticket with ONE sentence of context, for example:
         "User says Outlook on the web freezes a few times a day.
          Grab Logs output below."   <paste>
    4. A copy is also kept on the PC:
         C:\ProgramData\RMMScripts\Logs\Grab-Logs-<timestamp>.log

  RMM SETTINGS   : PowerShell | Run as System | Max run time 10 minutes
  EXIT CODES     : 0 = nothing flagged
                   1 = issues flagged (most RMMs show "Failed" - expected)
                   2 = script error
  PARAMETERS     : -Days 7 (history window)   -EventLines 30 (digest size)
                   -Full (also list built-in component extensions)

  VERSION : 0.2-DEV (2026-09-17)  after first production run: browser exit_type only
            flagged when the browser is closed, NTFS 98 (= volume healthy) dropped,
            UMDF user-mode driver crashes + USB4 dock-router events added,
            DisplayLink note, WU driver regex fixed, policy (default) skipped
            0.1-DEV (2026-09-17)  initial build for the Outlook-web-freeze
            case; conventions per README.md
================================================================================
#>
param(
    [int]$Days = 7,
    [int]$EventLines = 30,
    [switch]$Full
)

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        $fwd = @('-Days', $Days, '-EventLines', $EventLines)
        if ($Full) { $fwd += '-Full' }
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath @fwd
        exit $LASTEXITCODE
    }
}

$ScriptName    = 'Grab-Logs'
$ScriptVersion = '0.2-DEV'
$ErrorActionPreference = 'Continue'

$script:OutBuf = New-Object System.Collections.Generic.List[string]
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:Since  = (Get-Date).AddDays(-1 * $Days)
$script:Sw     = [Diagnostics.Stopwatch]::StartNew()

# ------------------------------- helpers --------------------------------------
function W    { param([string]$Text = '') $script:OutBuf.Add($Text) | Out-Null; Write-Output $Text }
function Flag { param([string]$Text) $script:Issues.Add($Text) | Out-Null }
function Sect { param([string]$Title) W ''; W (("---- {0} " -f $Title).PadRight(64, '-')) }

function Section {
    param([string]$Title, [scriptblock]$Body)
    Sect $Title
    try { & $Body } catch { W ("  (section '{0}' hit an error: {1})" -f $Title, $_.Exception.Message) }
}

function Trunc {
    param([string]$S, [int]$N)
    if ($null -eq $S) { return '' }
    if ($S.Length -le $N) { return $S }
    return ($S.Substring(0, [math]::Max(0, $N - 3)) + '...')
}

function OneLine { param([string]$S) if ($null -eq $S) { return '' }; return ($S -replace '\s+', ' ').Trim() }

function Save-Log {
    try {
        $dir = 'C:\ProgramData\RMMScripts\Logs'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $file = Join-Path $dir ("{0}-{1}.log" -f $ScriptName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $script:OutBuf | Set-Content -Path $file -Encoding UTF8
    } catch { }
}

function Finish {
    $script:Sw.Stop()
    W ''
    W ('=' * 64)
    W ("Collection took {0} s." -f [int]$script:Sw.Elapsed.TotalSeconds)
    W 'Notes for the reader:'
    W ("  - Collected by 'Grab Logs' ({0} v{1}) through the RMM, running as SYSTEM;" -f $ScriptName, $ScriptVersion)
    W '    per-user values come from the logged-on user registry hive and AppData.'
    W '  - n/a = not readable in this context, not necessarily a problem.'
    W ("  - Event counts cover the last {0} days; times are the PC local time." -f $Days)
    W '  - Flags below are heuristics to focus attention, not conclusions.'
    W ''
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
    if (-not $Path) { return $null }
    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $null }
    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [math]::Round($sum / 1MB)
    } catch { return $null }
}

# JSON reader that copes with multi-MB browser preference files
# (PS 5.1 ConvertFrom-Json caps at 2 MB and chokes on them)
function Read-JsonFile {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) { return $null }
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 200
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        return $ser.DeserializeObject($txt)
    } catch { return $null }
}

function JGet {
    param($Obj, [string]$Path)
    $cur = $Obj
    foreach ($k in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            $has = $false
            if ($cur.PSObject.Methods['ContainsKey']) { $has = $cur.ContainsKey($k) } else { $has = $cur.Contains($k) }
            if ($has) { $cur = $cur[$k] } else { return $null }
        } else { return $null }
    }
    return $cur
}

function Resolve-ExtName {
    param([string]$ProfDir, [string]$Id, [string]$Raw)
    if (-not $Raw) { return $Raw }
    if ($Raw -notmatch '^__MSG_(.+)__$') { return $Raw }
    $key = $Matches[1]
    $extRoot = Join-Path (Join-Path $ProfDir 'Extensions') $Id
    if (-not (Test-Path $extRoot -ErrorAction SilentlyContinue)) { return $Raw }
    $verDir = Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $verDir) { return $Raw }
    $man = Read-JsonFile (Join-Path $verDir.FullName 'manifest.json')
    $locales = @()
    $dl = JGet $man 'default_locale'
    if ($dl) { $locales += [string]$dl }
    $locales += @('en', 'en_US', 'en_GB')
    foreach ($loc in $locales) {
        $msgs = Read-JsonFile (Join-Path $verDir.FullName ("_locales\{0}\messages.json" -f $loc))
        if ($msgs -is [System.Collections.IDictionary]) {
            foreach ($k in @($msgs.Keys)) {
                if ($k -ieq $key) { $m = JGet $msgs[$k] 'message'; if ($m) { return [string]$m } }
            }
        }
    }
    return $Raw
}

function Get-EventsSafe {
    param([hashtable]$Filter, [int]$Max = 0)
    try {
        if ($Max -gt 0) { return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
        return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
    } catch { return @() }
}

function MBof { param($Procs) if (-not $Procs) { return 0 }; return [math]::Round((@($Procs) | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }

function Tm { param($Dt, [string]$Fmt = 'MM/dd HH:mm') if ($null -eq $Dt) { return '?' }; try { return ([datetime]$Dt).ToString($Fmt) } catch { return [string]$Dt } }


# =============================== main ===========================================
try {
    W ('=' * 64)
    W (" Grab Logs   ({0} v{1})   RMM Script Library" -f $ScriptName, $ScriptVersion)
    W ('=' * 64)
    W ' >>> Copy EVERYTHING from here down to the RESULT line and paste it into'
    W ' >>> the ticket together with one sentence describing the user complaint.'
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    W (" Window     : last {0} days (since {1})" -f $Days, $script:Since.ToString('yyyy-MM-dd HH:mm'))

    # ---------------------------------------------------------------- System
    Section 'System' {
        $os   = Get-CimInstance Win32_OperatingSystem
        $cs   = Get-CimInstance Win32_ComputerSystem
        $csp  = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $model = ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim()
        if ($csp -and $csp.Version -and $csp.Version -notmatch 'To be filled|Default|None|System Version') { $model += (" ({0})" -f $csp.Version.Trim()) }
        W ("Model         : {0}" -f $model)
        W ("Serial        : {0}" -f $(if ($bios) { $bios.SerialNumber } else { 'n/a' }))
        if ($bios) { W ("BIOS          : {0}  ({1})" -f $bios.SMBIOSBIOSVersion, (Tm $bios.ReleaseDate 'yyyy-MM-dd')) }
        $build = 'unknown'
        if ($cv) { $build = ("{0} build {1}.{2}" -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR) }
        W ("OS            : {0}  {1}" -f $os.Caption, $build)
        W ("OS installed  : {0}" -f (Tm $os.InstallDate 'yyyy-MM-dd'))
        $uptime = (Get-Date) - $os.LastBootUpTime
        W ("Last boot     : {0}   (uptime {1}d {2}h)" -f (Tm $os.LastBootUpTime 'yyyy-MM-dd HH:mm'), [int]$uptime.Days, $uptime.Hours)
        if ($uptime.TotalDays -gt 14) { Flag ("Uptime is {0} days - reboot before deeper troubleshooting" -f [int]$uptime.TotalDays) }
        $hiber = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        W ("Fast startup  : {0}" -f $(if ($hiber -eq 1) { 'ON (a shutdown does not fully restart Windows - uptime above is the real figure)' } elseif ($hiber -eq 0) { 'off' } else { 'n/a' }))
        $rebootCbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $rebootWu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        W ("Reboot pending: {0}" -f $(if ($rebootCbs -or $rebootWu) { 'YES' } else { 'no' }))
        if ($rebootCbs -or $rebootWu) { Flag 'A reboot is pending (servicing / Windows Update)' }
        W ("Time zone     : {0}" -f [TimeZoneInfo]::Local.DisplayName)
        $ds = & "$env:WINDIR\System32\dsregcmd.exe" /status 2>$null
        $join = @()
        foreach ($k in 'AzureAdJoined', 'DomainJoined', 'EnterpriseJoined') {
            $line = $ds | Where-Object { $_ -match ("^\s*{0}\s*:" -f $k) } | Select-Object -First 1
            if ($line) { $join += (OneLine $line) }
        }
        if ($join.Count) { W ("Join state    : {0}" -f ($join -join '; ')) }
    }

    # ---------------------------------------------------------- Logged-on user
    $script:UserDomain = $null; $script:UserName = $null; $script:UserSid = $null; $script:ProfilePath = $null; $script:Hku = $null
    Section 'Logged-on user' {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($owner -and $owner.User) { $script:UserDomain = $owner.Domain; $script:UserName = $owner.User }
        }
        if (-not $script:UserName) {
            $cs2 = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs2 -and $cs2.UserName) { $p = $cs2.UserName -split '\\', 2; if ($p.Count -eq 2) { $script:UserDomain = $p[0]; $script:UserName = $p[1] } }
        }
        if (-not $script:UserName) {
            W 'No interactive user is logged on - browser / Outlook / per-user checks will be skipped.'
            Flag 'No user was logged on during the run - re-run while the user is signed in to get browser + Outlook data'
            return
        }
        try {
            $script:UserSid = (New-Object Security.Principal.NTAccount($script:UserDomain, $script:UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
            $script:ProfilePath = (Get-ItemProperty ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}" -f $script:UserSid) -ErrorAction Stop).ProfileImagePath
        } catch { }
        if ($script:UserSid) {
            $script:Hku = "Registry::HKEY_USERS\$($script:UserSid)"
            if (-not (Test-Path $script:Hku)) { $script:Hku = $null }
        }
        W ("User          : {0}\{1}" -f $script:UserDomain, $script:UserName)
        W ("Profile       : {0}" -f $(if ($script:ProfilePath) { $script:ProfilePath } else { 'n/a' }))
        W ("User hive     : {0}" -f $(if ($script:Hku) { 'loaded' } else { 'not loaded (per-user registry checks limited)' }))
        if ($explorer -and $explorer.CreationDate) { W ("Signed in     : since {0}" -f (Tm $explorer.CreationDate 'yyyy-MM-dd HH:mm')) }
        $others = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' })
        W ("User profiles : {0} on this PC" -f $others.Count)
    }

    # ------------------------------------------------------ CPU / memory
    Section 'CPU / memory pressure' {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        W ("CPU           : {0}  ({1} cores / {2} logical)  load now {3}%" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.LoadPercentage)
        $totMB = [math]::Round($os.TotalVisibleMemorySize / 1KB); $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB)
        $usedPct = 0; if ($totMB -gt 0) { $usedPct = [math]::Round((($totMB - $freeMB) / $totMB) * 100) }
        W ("RAM           : {0} MB used of {1} MB ({2}%)" -f ($totMB - $freeMB), $totMB, $usedPct)
        $cTot = [math]::Round($os.TotalVirtualMemorySize / 1KB); $cFree = [math]::Round($os.FreeVirtualMemory / 1KB)
        $cPct = 0; if ($cTot -gt 0) { $cPct = [math]::Round((($cTot - $cFree) / $cTot) * 100) }
        W ("Commit charge : {0} MB of {1} MB limit ({2}%)" -f ($cTot - $cFree), $cTot, $cPct)
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        foreach ($p in $pf) { W ("Page file     : {0}  {1} MB allocated, {2} MB in use (peak {3} MB)" -f $p.Name, $p.AllocatedBaseSize, $p.CurrentUsage, $p.PeakUsage) }
        if ($pf.Count -eq 0) { W 'Page file     : none / n/a' }
        if ($usedPct -ge 90) { Flag ("Memory pressure: {0}% of RAM in use" -f $usedPct) }
        if ($cPct -ge 90) { Flag ("Commit charge at {0}% of the limit - the system will page heavily and stall" -f $cPct) }

        W 'Top RAM (working set, grouped by process):'
        Get-Process -ErrorAction SilentlyContinue | Group-Object Name | ForEach-Object {
            New-Object psobject -Property @{ Name = $_.Name; MB = (MBof $_.Group); N = $_.Count }
        } | Sort-Object MB -Descending | Select-Object -First 8 | ForEach-Object { W ("  {0,-30} {1,7} MB  (x{2})" -f $_.Name, $_.MB, $_.N) }

        $cores = [Environment]::ProcessorCount
        $s1 = @{}
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $s1[$_.Id] = $_.TotalProcessorTime.TotalMilliseconds } catch { } }
        Start-Sleep -Seconds 3
        $deltas = @{}
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($s1.ContainsKey($_.Id)) {
                    $d = $_.TotalProcessorTime.TotalMilliseconds - $s1[$_.Id]
                    if ($d -gt 0) { if ($deltas.ContainsKey($_.Name)) { $deltas[$_.Name] += $d } else { $deltas[$_.Name] = $d } }
                }
            } catch { }
        }
        W 'Top CPU (3-second sample):'
        $printed = 0
        foreach ($t in ($deltas.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6)) {
            $pct = [math]::Round(($t.Value / 3000 / $cores) * 100, 1)
            if ($pct -ge 0.5) { W ("  {0,-30} {1,5}%" -f $t.Key, $pct); $printed++ }
            if ($pct -gt 60) { Flag ("'{0}' was using {1}% of total CPU during the sample" -f $t.Key, $pct) }
        }
        if ($printed -eq 0) { W '  (idle - nothing above 0.5% of total CPU)' }
        $tot = ($deltas.Values | Measure-Object -Sum).Sum
        if ($tot) { W ("  total CPU during sample ~{0}%" -f [math]::Round(($tot / 3000 / $cores) * 100)) }
    }

    # ------------------------------------------------------ GPU / display
    Section 'GPU / display' {
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
            $dd = Tm $g.DriverDate 'yyyy-MM-dd'
            W ("GPU           : {0}  driver {1} ({2})  status {3}" -f $g.Name, $g.DriverVersion, $dd, $g.Status)
            if ($g.DriverDate -and $g.DriverDate -lt (Get-Date).AddMonths(-24)) { Flag ("Display driver for '{0}' is dated {1} - over 2 years old" -f $g.Name, $dd) }
            if ($g.ConfigManagerErrorCode -ne 0) { Flag ("GPU '{0}' reports device error code {1}" -f $g.Name, $g.ConfigManagerErrorCode) }
        }
        $dl = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'DisplayLink' })
        if ($dl.Count -gt 0) { W ("DisplayLink   : {0} USB graphics adapter(s), driver {1} - external monitors run through a DisplayLink dock; frozen/laggy screens on those monitors are a dock/driver symptom, not the app" -f $dl.Count, $dl[0].DriverVersion) }
        $gd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue
        $hws = $null; if ($gd) { $hws = $gd.HwSchMode }
        W ("HW GPU sched  : {0}" -f $(if ($hws -eq 2) { 'on' } elseif ($hws -eq 1) { 'off' } else { 'default / n/a' }))
        $mpo = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -ErrorAction SilentlyContinue).OverlayTestMode
        W ("MPO override  : {0}" -f $(if ($mpo -eq 5) { 'OverlayTestMode=5 (multi-plane overlay disabled)' } else { 'not set' }))
        $mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue)
        if ($mons.Count) {
            $names = foreach ($m in $mons) { if ($m.UserFriendlyName) { ([Text.Encoding]::ASCII.GetString([byte[]]$m.UserFriendlyName) -replace '\0', '').Trim() } else { 'unknown' } }
            W ("Monitors      : {0}  [{1}]" -f $mons.Count, ($names -join ', '))
        }
        $tdr = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $script:Since }
        W ("GPU resets    : {0} 'display driver stopped responding' event(s) (4101) in {1} days" -f $tdr.Count, $Days)
        if ($tdr.Count -gt 0) {
            $l = $tdr | Sort-Object TimeCreated -Descending | Select-Object -First 1
            W ("  latest {0}: {1}" -f (Tm $l.TimeCreated), (Trunc (OneLine $l.Message) 120))
            Flag ("{0} GPU driver reset(s) (TDR, event 4101) in {1} days - the display driver is hanging; update/roll back the GPU driver, try browser GPU acceleration off" -f $tdr.Count, $Days)
        }
    }

    # ------------------------------------------------------------ Storage
    Section 'Storage' {
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            if ($d.Size -gt 0) {
                $freeGB = [math]::Round($d.FreeSpace / 1GB, 1); $sizeGB = [math]::Round($d.Size / 1GB, 1); $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100)
                W ("Volume {0}      : {1} GB free of {2} GB ({3}% free)" -f $d.DeviceID, $freeGB, $sizeGB, $pct)
                if ($pct -lt 10 -or $freeGB -lt 15) { Flag ("Volume {0} is low on space ({1} GB / {2}% free)" -f $d.DeviceID, $freeGB, $pct) }
            }
        }
        foreach ($p in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            W ("Disk          : {0}  {1}  {2}  {3} GB  health {4}" -f $p.FriendlyName, $p.MediaType, $p.BusType, [math]::Round($p.Size / 1GB), $p.HealthStatus)
            if ($p.HealthStatus -and "$($p.HealthStatus)" -ne 'Healthy') { Flag ("Physical disk '{0}' health is {1}" -f $p.FriendlyName, $p.HealthStatus) }
            $rc = $null; try { $rc = $p | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
            if ($rc) {
                W ("  wear {0}%  temp {1}C  read errs {2}  write errs {3}  power-on {4} h" -f $(if ($null -ne $rc.Wear) { $rc.Wear } else { '?' }), $(if ($rc.Temperature) { $rc.Temperature } else { '?' }), $(if ($null -ne $rc.ReadErrorsTotal) { $rc.ReadErrorsTotal } else { '?' }), $(if ($null -ne $rc.WriteErrorsTotal) { $rc.WriteErrorsTotal } else { '?' }), $(if ($null -ne $rc.PowerOnHours) { $rc.PowerOnHours } else { '?' }))
                if ($rc.Wear -ge 80) { Flag ("Disk '{0}' wear is {1}% - nearing end of life" -f $p.FriendlyName, $rc.Wear) }
                if (($rc.ReadErrorsUncorrected -gt 0) -or ($rc.WriteErrorsUncorrected -gt 0)) { Flag ("Disk '{0}' has uncorrected read/write errors" -f $p.FriendlyName) }
            } else { W '  reliability counters: n/a' }
        }
        $ids = @{ 129 = 'reset to device (controller hang)'; 153 = 'IO retried'; 157 = 'disk surprise-removed'; 7 = 'bad block'; 11 = 'controller error'; 51 = 'paging error'; 55 = 'NTFS corruption'; 140 = 'NTFS flush failure' }
        $stor = @((Get-EventsSafe @{ LogName = 'System'; Id = 7, 11, 51, 55, 129, 140, 153, 157; StartTime = $script:Since }) | Where-Object { $_.ProviderName -match 'disk|stor|Ntfs|nvme|sata|volmgr|partmgr' })
        W ("Storage events: {0} disk / controller / NTFS event(s) in {1} days" -f $stor.Count, $Days)
        if ($stor.Count -gt 0) {
            $stor | Group-Object { "{0} {1}" -f $_.ProviderName, $_.Id } | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
                W ("  {0,-22} x{1}  ({2})" -f $_.Name, $_.Count, $ids[[int]$_.Group[0].Id])
            }
            Flag ("{0} storage event(s) (disk reset / IO retry / NTFS) in {1} days - whole-system stalls often trace to this; check disk health + storage driver" -f $stor.Count, $Days)
        }
    }

    # ------------------------------------------------------ Power / battery
    Section 'Power / battery' {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        $onAc = $null
        if ($bat) {
            $statusMap = @{ 1 = 'discharging'; 2 = 'on AC'; 3 = 'fully charged'; 4 = 'low'; 5 = 'critical'; 6 = 'charging'; 7 = 'charging (high)'; 8 = 'charging (low)'; 9 = 'charging (critical)'; 10 = 'unknown'; 11 = 'partially charged' }
            $bs = $statusMap[[int]$bat.BatteryStatus]; if (-not $bs) { $bs = "code $($bat.BatteryStatus)" }
            $onAc = ([int]$bat.BatteryStatus -ne 1)
            W ("Battery       : {0}%  ({1})" -f $bat.EstimatedChargeRemaining, $bs)
            try {
                $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Measure-Object FullChargedCapacity -Sum).Sum
                $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Measure-Object DesignedCapacity -Sum).Sum
                if ($design -gt 0 -and $full -gt 0) {
                    $wear = 100 - [math]::Round(($full / $design) * 100)
                    W ("Battery wear  : {0}% (design {1} mWh, full-charge {2} mWh)" -f $wear, $design, $full)
                    if ($wear -gt 40) { Flag ("Battery has lost {0}% of design capacity - consider replacement" -f $wear) }
                }
            } catch { W 'Battery wear  : n/a' }
        } else { W 'Battery       : none (desktop / VM)' }
        W ("Power source  : {0}" -f $(if ($null -eq $onAc) { 'AC (no battery)' } elseif ($onAc) { 'AC' } else { 'battery' }))
        $scheme = powercfg /getactivescheme 2>$null
        if ($scheme) { $sl = ($scheme -join ' '); if ($sl -match '\(([^)]+)\)') { W ("Power plan    : {0}" -f $Matches[1]) } else { W ("Power plan    : {0}" -f (OneLine $sl)) } }
        $ov = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue
        $ovMap = @{ 'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best performance'; '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Better performance'; '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency'; '00000000-0000-0000-0000-000000000000' = 'Balanced (default)' }
        foreach ($pair in @(@('AC', 'ActiveOverlayAcPowerScheme'), @('battery', 'ActiveOverlayDcPowerScheme'))) {
            $g = $null; if ($ov) { $g = [string]$ov.($pair[1]) }
            if ($g) { $n = $ovMap[$g.ToLower()]; if (-not $n) { $n = $g }; W ("Power mode    : on {0} = {1}" -f $pair[0], $n) }
        }
        $thr = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $script:Since }
        W ("CPU throttle  : {0} 'processor speed limited by firmware' event(s) (id 37) in {1} days" -f $thr.Count, $Days)
        if ($thr.Count -ge 3) { Flag ("CPU was throttled by firmware {0} time(s) in {1} days - thermal/power limits; check cooling, BIOS, power mode" -f $thr.Count, $Days) }
        $ss = powercfg /a 2>$null
        if ($ss) { $line = $ss | Where-Object { $_ -match 'Standby \(S0 Low Power Idle\)|Standby \(S3\)' } | Select-Object -First 1; if ($line) { W ("Sleep model   : {0}" -f (OneLine $line)) } }
    }

    # --------------------------------------------------- Devices with errors
    Section 'Devices with error codes' {
        $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue)
        if ($bad.Count -eq 0) { W 'none' }
        foreach ($b in ($bad | Select-Object -First 10)) {
            $code = [int]$b.ConfigManagerErrorCode
            W ("  code {0,-3} {1}{2}" -f $code, (Trunc $b.Name 60), $(if ($code -eq 22) { '  (disabled)' } else { '' }))
            if ($code -ne 22) { Flag ("Device '{0}' has error code {1} (10 = cannot start, 28 = no driver, 43 = driver reported failure)" -f $b.Name, $code) }
        }
    }


    # ---------------------------------------------------------- Stability
    Section ("Stability - last {0} days" -f $Days) {
        $bsod = @((Get-EventsSafe @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $script:Since }) | Where-Object { $_.ProviderName -in @('Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-WER-SystemErrorReporting', 'EventLog') })
        $whea = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $script:Since }
        W ("Unexpected shutdowns / bugchecks : {0}" -f $bsod.Count)
        foreach ($b in ($bsod | Sort-Object TimeCreated -Descending | Select-Object -First 3)) { W ("  {0}  {1} {2}: {3}" -f (Tm $b.TimeCreated), $b.ProviderName, $b.Id, (Trunc (OneLine $b.Message) 110)) }
        if ($bsod.Count -gt 0) { Flag ("{0} unexpected shutdown / bugcheck event(s) in {1} days" -f $bsod.Count, $Days) }
        W ("WHEA hardware errors             : {0}" -f $whea.Count)
        if ($whea.Count -gt 0) { Flag ("{0} WHEA hardware error event(s) in {1} days (CPU/PCIe/memory) - check for firmware updates" -f $whea.Count, $Days) }
        $lowmem = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = $script:Since }
        W ("Low virtual-memory warnings      : {0} (event 2004)" -f $lowmem.Count)
        if ($lowmem.Count -gt 0) {
            $l = $lowmem | Sort-Object TimeCreated -Descending | Select-Object -First 1
            W ("  latest {0}: {1}" -f (Tm $l.TimeCreated), (Trunc (OneLine $l.Message) 300))
            Flag ("Windows ran low on virtual memory {0} time(s) in {1} days - see the processes named in the 2004 event" -f $lowmem.Count, $Days)
        }
        $svc = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $script:Since }
        W ("Services terminated unexpectedly : {0}" -f $svc.Count)
        if ($svc.Count -gt 0) {
            $svc | Group-Object { try { [string]$_.Properties[0].Value } catch { '?' } } | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { W ("  {0,-44} x{1}" -f (Trunc $_.Name 44), $_.Count) }
        }
        $umdf = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-DriverFrameworks-UserMode'; Id = 10110, 10111, 10120, 10121; StartTime = $script:Since }
        W ("User-mode driver crashes (UMDF)  : {0}" -f $umdf.Count)
        if ($umdf.Count -gt 0) {
            $l = $umdf | Sort-Object TimeCreated -Descending | Select-Object -First 1
            W ("  latest {0}: {1}" -f (Tm $l.TimeCreated), (Trunc (OneLine $l.Message) 170))
            Flag ("{0} user-mode driver crash event(s) in {1} days - a USB dock / DisplayLink / printer / camera driver died and restarted (device named above); screens or USB devices freeze while it recovers" -f $umdf.Count, $Days)
        }
        $usb4 = Get-EventsSafe @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-USB-USB4DeviceRouter-EventLogs'; StartTime = $script:Since }
        if ($usb4.Count -gt 0) {
            $l = $usb4 | Sort-Object TimeCreated -Descending | Select-Object -First 1
            W ("USB4 / dock router events        : {0}  (latest {1}: {2})" -f $usb4.Count, (Tm $l.TimeCreated), (Trunc (OneLine $l.Message) 120))
        }
        $mini = @(Get-ChildItem 'C:\Windows\Minidump' -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $script:Since })
        $mem  = Get-Item 'C:\Windows\MEMORY.DMP' -ErrorAction SilentlyContinue
        $lkr  = @(Get-ChildItem 'C:\Windows\LiveKernelReports' -Recurse -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $script:Since })
        W ("Crash dumps in window            : minidumps {0}, live kernel reports {1}{2}" -f $mini.Count, $lkr.Count, $(if ($mem) { ", MEMORY.DMP dated $(Tm $mem.LastWriteTime 'yyyy-MM-dd')" } else { '' }))
        foreach ($k in ($lkr | Sort-Object LastWriteTime -Descending | Select-Object -First 5)) { W ("  {0}  {1}\{2}" -f (Tm $k.LastWriteTime), $k.Directory.Name, $k.Name) }
        if ($lkr.Count -gt 0) { Flag ("{0} live kernel report(s) in {1} days (folder name = subsystem: WATCHDOG = GPU/driver hang, USB* = USB, NDIS = network driver)" -f $lkr.Count, $Days) }

        $apps = Get-EventsSafe @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = $script:Since }
        W ''
        W ("App hangs + crashes (Application Hang 1002 / Application Error 1000): {0}" -f $apps.Count)
        if ($apps.Count -gt 0) {
            $rows = foreach ($e in $apps) {
                $p = $e.Properties; $app = 'unknown'; $mod = ''; $code = ''
                try { if ($p.Count -gt 0) { $app = [string]$p[0].Value } } catch { }
                if ($e.ProviderName -eq 'Application Error') { try { $mod = [string]$p[3].Value; $code = [string]$p[6].Value } catch { } }
                New-Object psobject -Property @{ Time = $e.TimeCreated; Kind = $(if ($e.ProviderName -eq 'Application Hang') { 'HANG ' } else { 'CRASH' }); App = $app; Module = $mod; Code = $code }
            }
            W '  by process:'
            $rows | Group-Object App | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
                $h = @($_.Group | Where-Object { $_.Kind -eq 'HANG ' }).Count; $c = $_.Count - $h
                W ("    {0,-30} hangs {1,3}  crashes {2,3}" -f $_.Name, $h, $c)
                if ($_.Count -ge 3) { Flag ("'{0}' hung/crashed {1} times in {2} days" -f $_.Name, $_.Count, $Days) }
                elseif ($_.Name -match '^(msedge|chrome|firefox|brave|opera|olk|msedgewebview2|OUTLOOK|ms-teams)\.exe$') { Flag ("'{0}' hung/crashed {1} time(s) in {2} days - matches a browser / Outlook complaint" -f $_.Name, $_.Count, $Days) }
            }
            W '  most recent (time, type, process, faulting module / exception code):'
            foreach ($r in ($rows | Sort-Object Time -Descending | Select-Object -First 12)) {
                $extra = ''; if ($r.Module) { $extra = ("  {0} {1}" -f $r.Module, $r.Code) }
                W ("    {0}  {1} {2}{3}" -f (Tm $r.Time), $r.Kind, $r.App, $extra)
            }
            $gpuMod = @($rows | Where-Object { $_.Module -match '^(amd|ati|atikm|igd|igc|igxel|nv|nvwgf|nvd3d|d3d|dxgi|libglesv2|libegl)' })
            if ($gpuMod.Count -gt 0) { Flag ("{0} crash(es) faulted inside a graphics module ({1}) - points at the display driver / GPU acceleration" -f $gpuMod.Count, (($gpuMod | Select-Object -ExpandProperty Module -Unique | Select-Object -First 3) -join ', ')) }
        }

        $wer = Get-EventsSafe @{ LogName = 'Application'; ProviderName = 'Windows Error Reporting'; Id = 1001; StartTime = $script:Since }
        W ''
        W ("Windows Error Reporting buckets (1001): {0}" -f $wer.Count)
        if ($wer.Count -gt 0) {
            $wr = foreach ($e in $wer) {
                $p = $e.Properties; $en = ''; $p1 = ''; $p2 = ''
                try { $en = [string]$p[2].Value; $p1 = [string]$p[5].Value; $p2 = [string]$p[6].Value } catch { }
                New-Object psobject -Property @{ Time = $e.TimeCreated; EventName = $en; P1 = $p1; P2 = $p2 }
            }
            $wr | Group-Object { "{0} | {1}" -f $_.EventName, $_.P1 } | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
                $last = ($_.Group | Sort-Object Time -Descending | Select-Object -First 1).Time
                W ("  {0,-52} x{1,-3} latest {2}" -f (Trunc $_.Name 52), $_.Count, (Tm $last))
            }
            $lke = @($wr | Where-Object { $_.EventName -eq 'LiveKernelEvent' })
            if ($lke.Count -gt 0) { Flag ("{0} LiveKernelEvent(s): code(s) {1} (141/117 = GPU hang, 144 = USB, 1a8/1ab = watchdog/driver)" -f $lke.Count, (($lke | Select-Object -ExpandProperty P1 -Unique) -join ',')) }
            if (@($wr | Where-Object { $_.EventName -match 'AppHangXProc' }).Count -gt 0) { W '  note: AppHangXProcB1 = the app was blocked waiting on ANOTHER process (P1 = the app that appeared hung)' }
        }

        $perf = Get-EventsSafe @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Level = 1, 2, 3; StartTime = $script:Since }
        W ''
        W ("Performance-diagnostics events (boot / shutdown / desktop degradation): {0}" -f $perf.Count)
        $perf | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
            $l = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            W ("  id {0,-4} x{1,-3} latest {2}: {3}" -f $_.Name, $_.Count, (Tm $l.TimeCreated), (Trunc (OneLine $l.Message) 100))
        }
    }

    # ---------------------------------------------------- Browsers / web apps
    Section 'Browsers and web apps (logged-on user)' {
        if (-not $script:ProfilePath) { W 'skipped - no logged-on user profile'; return }
        $prof = $script:ProfilePath
        $script:DefaultProgId = $null
        if ($script:Hku) { $script:DefaultProgId = (Get-ItemProperty "$($script:Hku)\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -ErrorAction SilentlyContinue).ProgId }
        $defName = $script:DefaultProgId
        if ($defName -like 'MSEdgeHTM*') { $defName = 'Microsoft Edge' } elseif ($defName -like 'ChromeHTML*') { $defName = 'Google Chrome' } elseif ($defName -like 'FirefoxURL*') { $defName = 'Firefox' } elseif ($defName -like 'BraveHTML*') { $defName = 'Brave' } elseif ($defName -like 'Opera*') { $defName = 'Opera' }
        W ("Default browser (https): {0}" -f $(if ($defName) { $defName } else { 'n/a' }))
        $wvVer = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue).pv
        $wv = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue)
        W ("WebView2 runtime: {0}; {1} process(es), {2} MB (used by new Outlook, Teams, Office add-ins)" -f $(if ($wvVer) { $wvVer } else { 'n/a' }), $wv.Count, (MBof $wv))

        $browsers = @(
            @{ Name = 'Microsoft Edge'; Proc = 'msedge'; ProgId = 'MSEdgeHTM'; Exe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"); UserData = (Join-Path $prof 'AppData\Local\Microsoft\Edge\User Data'); Single = $false },
            @{ Name = 'Google Chrome'; Proc = 'chrome'; ProgId = 'ChromeHTML'; Exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", (Join-Path $prof 'AppData\Local\Google\Chrome\Application\chrome.exe')); UserData = (Join-Path $prof 'AppData\Local\Google\Chrome\User Data'); Single = $false },
            @{ Name = 'Brave'; Proc = 'brave'; ProgId = 'BraveHTML'; Exe = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe", (Join-Path $prof 'AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe')); UserData = (Join-Path $prof 'AppData\Local\BraveSoftware\Brave-Browser\User Data'); Single = $false },
            @{ Name = 'Opera'; Proc = 'opera'; ProgId = 'Opera'; Exe = @((Join-Path $prof 'AppData\Local\Programs\Opera\opera.exe'), (Join-Path $prof 'AppData\Local\Programs\Opera\launcher.exe'), "$env:ProgramFiles\Opera\opera.exe"); UserData = (Join-Path $prof 'AppData\Roaming\Opera Software\Opera Stable'); Single = $true }
        )
        foreach ($B in $browsers) {
            $exe = $null
            foreach ($c in $B.Exe) { if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) { $exe = $c; break } }
            $procs = @(Get-Process -Name $B.Proc -ErrorAction SilentlyContinue)
            $hasData = (Test-Path $B.UserData -ErrorAction SilentlyContinue)
            if (-not $exe -and -not $hasData -and $procs.Count -eq 0) { continue }
            $ver = 'n/a'; if ($exe) { try { $ver = (Get-Item $exe).VersionInfo.ProductVersion } catch { } }
            $isDefault = ($script:DefaultProgId -and ($script:DefaultProgId -like ($B.ProgId + '*')))
            $runTxt = 'not running'
            if ($procs.Count -gt 0) {
                $oldest = $null; try { $oldest = ($procs | Sort-Object StartTime | Select-Object -First 1).StartTime } catch { }
                $runTxt = ("running: {0} processes, {1} MB{2}" -f $procs.Count, (MBof $procs), $(if ($oldest) { ", open since $(Tm $oldest)" } else { '' }))
            }
            W ''
            W ("{0} {1}{2} - {3}" -f $B.Name, $ver, $(if ($isDefault) { '  [DEFAULT BROWSER]' } else { '' }), $runTxt)
            if (-not $hasData) { W '  no profile data for the logged-on user'; continue }
            $ls = Read-JsonFile (Join-Path $B.UserData 'Local State')
            $hw = JGet $ls 'hardware_acceleration_mode.enabled'
            W ("  GPU acceleration : {0}" -f $(if ($null -eq $hw) { 'default (on)' } elseif ($hw) { 'on' } else { 'OFF (disabled by user or policy)' }))
            $labs = JGet $ls 'browser.enabled_labs_experiments'
            if ($labs -and @($labs).Count -gt 0) { W ("  flags set        : {0}" -f (Trunc ((@($labs) | Select-Object -First 8) -join ', ') 160)) }
            $bg = JGet $ls 'background_mode.enabled'; if ($null -ne $bg) { W ("  background mode  : {0}" -f $bg) }
            $dmps = @(Get-ChildItem (Join-Path $B.UserData 'Crashpad\reports') -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $script:Since })
            W ("  crash dumps      : {0} in {1} days{2}" -f $dmps.Count, $Days, $(if ($dmps.Count -gt 0) { ' (latest ' + (($dmps | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Tm $_.LastWriteTime }) -join ', ') + ')' } else { '' }))
            if ($dmps.Count -ge 3) { Flag ("{0} wrote {1} crash dump(s) in {2} days" -f $B.Name, $dmps.Count, $Days) }
            if ($B.Single) { $profDirs = @(Get-Item $B.UserData) }
            else { $profDirs = @(Get-ChildItem $B.UserData -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'Preferences') }) }
            W ("  profiles         : {0}" -f $profDirs.Count)
            foreach ($pd in ($profDirs | Select-Object -First 4)) {
                $prefs  = Read-JsonFile (Join-Path $pd.FullName 'Preferences')
                $sprefs = Read-JsonFile (Join-Path $pd.FullName 'Secure Preferences')
                $pname = JGet $prefs 'profile.name'; if (-not $pname) { $pname = $pd.Name }
                $exit = JGet $prefs 'profile.exit_type'
                $pfile = Get-Item (Join-Path $pd.FullName 'Preferences') -ErrorAction SilentlyContinue
                W ("  - profile '{0}' ({1})  last exit: {2}  prefs written {3}" -f $pname, $pd.Name, $(if ($exit) { $exit } else { 'n/a' }), (Tm $pfile.LastWriteTime))
                if ($exit -eq 'Crashed' -and $procs.Count -eq 0) { Flag ("{0} profile '{1}' last exit type is 'Crashed' - the browser did not close cleanly" -f $B.Name, $pname) }
                elseif ($exit -eq 'Crashed') { W "    (exit type 'Crashed' is normal while the browser is still running - it resets on a clean close)" }
                $exts = @{}
                foreach ($j in @($prefs, $sprefs)) {
                    $settings = JGet $j 'extensions.settings'
                    if ($settings -is [System.Collections.IDictionary]) {
                        foreach ($id in @($settings.Keys)) {
                            $e = $settings[$id]; if ($e -isnot [System.Collections.IDictionary]) { continue }
                            $loc = JGet $e 'location'; $name = JGet $e 'manifest.name'; $mver = JGet $e 'manifest.version'
                            $st = JGet $e 'state'; $dr = JGet $e 'disable_reasons'
                            $enabled = $true
                            if ($null -ne $st) { $enabled = ([int]$st -eq 1) } elseif ($dr -and @($dr).Count -gt 0) { $enabled = $false }
                            if (-not $name) { if (-not $Full) { continue } else { $name = "(unnamed $id)" } }
                            $exts[$id] = @{ Name = [string]$name; Ver = [string]$mver; Loc = $loc; Enabled = $enabled }
                        }
                    }
                }
                $comp = 0; $shown = New-Object System.Collections.Generic.List[string]
                foreach ($id in @($exts.Keys)) {
                    $x = $exts[$id]
                    if (($x.Loc -eq 5 -or $x.Loc -eq 10) -and -not $Full) { $comp++; continue }
                    $nm = Resolve-ExtName $pd.FullName $id $x.Name
                    $locTxt = switch ([int]$x.Loc) { 1 { 'user' } 9 { 'POLICY' } 7 { 'POLICY' } 3 { 'external' } 2 { 'external' } 6 { 'external' } 4 { 'unpacked' } 8 { 'cmdline' } 5 { 'component' } 10 { 'component' } default { "loc$($x.Loc)" } }
                    $shown.Add(("      {0,-40} {1,-12} {2,-9} {3,-9} {4}" -f (Trunc $nm 40), (Trunc $x.Ver 12), $(if ($x.Enabled) { 'enabled' } else { 'DISABLED' }), $locTxt, $id)) | Out-Null
                }
                W ("    extensions: {0} listed ({1} built-in component extensions hidden)" -f $shown.Count, $comp)
                foreach ($l in ($shown | Sort-Object)) { W $l }
                if ($shown.Count -ge 8) { Flag ("{0} profile '{1}' has {2} extensions - extensions are the most common cause of web-app freezes; test in an InPrivate / guest window" -f $B.Name, $pname, $shown.Count) }
                $owaDbs = @(Get-ChildItem (Join-Path $pd.FullName 'IndexedDB') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'outlook|office' })
                foreach ($db in ($owaDbs | Select-Object -First 4)) {
                    $mb = Get-FolderSizeMB $db.FullName
                    W ("    site data : {0}  {1} MB" -f (Trunc $db.Name 55), $mb)
                    if ($mb -gt 1500) { Flag ("{0}: IndexedDB store '{1}' is {2} MB - Outlook web offline data may be bloated; clearing site data for outlook.office.com is a safe fix" -f $B.Name, $db.Name, $mb) }
                }
                $cache = Join-Path $pd.FullName 'Cache\Cache_Data'; if (-not (Test-Path $cache -ErrorAction SilentlyContinue)) { $cache = Join-Path $pd.FullName 'Cache' }
                $cmb = Get-FolderSizeMB $cache; if ($null -ne $cmb) { W ("    http cache: {0} MB" -f $cmb) }
            }
        }

        # Firefox
        $ffExe = $null
        foreach ($c in @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe", (Join-Path $prof 'AppData\Local\Mozilla Firefox\firefox.exe'))) { if (Test-Path $c -ErrorAction SilentlyContinue) { $ffExe = $c; break } }
        $ffProcs = @(Get-Process firefox -ErrorAction SilentlyContinue)
        $ffRoot = Join-Path $prof 'AppData\Roaming\Mozilla\Firefox\Profiles'
        if ($ffExe -or $ffProcs.Count -gt 0 -or (Test-Path $ffRoot -ErrorAction SilentlyContinue)) {
            $fv = 'n/a'; if ($ffExe) { try { $fv = (Get-Item $ffExe).VersionInfo.ProductVersion } catch { } }
            W ''
            W ("Firefox {0}{1} - {2}" -f $fv, $(if ($script:DefaultProgId -like 'FirefoxURL*') { '  [DEFAULT BROWSER]' } else { '' }), $(if ($ffProcs.Count) { "running: $($ffProcs.Count) processes, $(MBof $ffProcs) MB" } else { 'not running' }))
            foreach ($fp in @(Get-ChildItem $ffRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'extensions.json') } | Select-Object -First 3)) {
                $ej = Read-JsonFile (Join-Path $fp.FullName 'extensions.json')
                $addons = JGet $ej 'addons'
                $list = @()
                if ($addons) { foreach ($a in @($addons)) { if ((JGet $a 'type') -eq 'extension' -and -not (JGet $a 'hidden')) { $list += ("{0} {1}{2}" -f (JGet $a 'defaultLocale.name'), (JGet $a 'version'), $(if (JGet $a 'active') { '' } else { ' (disabled)' })) } } }
                W ("  - profile {0}: {1} extension(s){2}" -f $fp.Name, $list.Count, $(if ($list.Count) { ': ' + (Trunc ($list -join '; ') 200) } else { '' }))
                $pj = Join-Path $fp.FullName 'prefs.js'
                if (Test-Path $pj) { $gfx = @(Select-String -Path $pj -Pattern 'layers\.acceleration|gfx\.webrender|browser\.tabs\.remote\.autostart' -ErrorAction SilentlyContinue | Select-Object -First 4); foreach ($gl in $gfx) { W ("      {0}" -f (Trunc (OneLine $gl.Line) 100)) } }
            }
        }

        # Browser policies (Intune / GPO)
        W ''
        foreach ($pol in @(@('Edge', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'), @('Edge', "$($script:Hku)\Software\Policies\Microsoft\Edge"), @('Chrome', 'HKLM:\SOFTWARE\Policies\Google\Chrome'), @('Chrome', "$($script:Hku)\Software\Policies\Google\Chrome"))) {
            $r = $pol[1]
            if (-not $script:Hku -and $r -like 'Registry::*') { continue }
            if (-not (Test-Path $r -ErrorAction SilentlyContinue)) { continue }
            $p = Get-ItemProperty $r -ErrorAction SilentlyContinue
            $vals = @(); if ($p) { $vals = @($p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Name -ne '(default)' } | ForEach-Object { "{0}={1}" -f $_.Name, (Trunc ([string]$_.Value) 40) }) }
            $subs = @(Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
            W ("{0} policies ({1}): {2} value(s){3}" -f $pol[0], $(if ($r -like 'HKLM*') { 'machine' } else { 'user' }), $vals.Count, $(if ($subs.Count) { '; lists: ' + ($subs -join ', ') } else { '' }))
            foreach ($v in ($vals | Select-Object -First 20)) { W ("  {0}" -f $v) }
            $fl = Join-Path $r 'ExtensionInstallForcelist'
            if (Test-Path $fl -ErrorAction SilentlyContinue) { (Get-ItemProperty $fl).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Select-Object -First 10 | ForEach-Object { W ("  forced extension: {0}" -f (Trunc ([string]$_.Value) 90)) } }
        }
        if (-not (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge') -and -not (Test-Path 'HKLM:\SOFTWARE\Policies\Google\Chrome')) { W 'Browser policies: none at machine level' }
    }


    # ------------------------------------------------ Outlook / Teams / OneDrive
    Section 'Outlook / Teams / OneDrive' {
        $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
        if ($c2r) {
            $channelMap = @{ '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'; '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'; '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise'; '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise'; 'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual (Preview)'; '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta' }
            $chan = [string]$c2r.UpdateChannel; $chanName = $chan
            foreach ($k in $channelMap.Keys) { if ($chan -match $k) { $chanName = $channelMap[$k] } }
            W ("Office C2R    : {0}  {1}  [{2}]" -f $c2r.VersionToReport, $chanName, (Trunc ([string]$c2r.ProductReleaseIds) 50))
        } else { W 'Office C2R    : not installed' }
        $olRun = @(Get-Process OUTLOOK -ErrorAction SilentlyContinue)
        W ("Classic Outlook: {0}" -f $(if ($olRun.Count) { "running ($(MBof $olRun) MB)" } else { 'not running' }))
        if ($script:Hku) {
            $useNew = (Get-ItemProperty "$($script:Hku)\Software\Microsoft\Office\16.0\Outlook\Preferences" -ErrorAction SilentlyContinue).UseNewOutlook
            W ("New Outlook toggle: {0}" -f $(if ($useNew -eq 1) { 'ON (user switched to new Outlook)' } elseif ($null -ne $useNew) { 'off' } else { 'not set' }))
            foreach ($resil in @(@('Disabled items', "$($script:Hku)\Software\Microsoft\Office\16.0\Outlook\Resiliency\DisabledItems"), @('Crashing add-ins', "$($script:Hku)\Software\Microsoft\Office\16.0\Outlook\Resiliency\CrashingAddinList"))) {
                $cnt = 0; if (Test-Path $resil[1]) { $cnt = @((Get-Item $resil[1] -ErrorAction SilentlyContinue).Property).Count }
                if ($cnt -gt 0) { W ("Outlook {0,-16}: {1}" -f $resil[0], $cnt); Flag ("Classic Outlook has {0} entry(ies) under '{1}' - an add-in was disabled or crashing" -f $cnt, $resil[0]) }
            }
        }
        $olk = $null; try { $olk = Get-AppxPackage -AllUsers -Name 'Microsoft.OutlookForWindows' -ErrorAction Stop | Select-Object -First 1 } catch { }; if (-not $olk) { try { $olk = Get-AppxPackage -Name 'Microsoft.OutlookForWindows' -ErrorAction Stop | Select-Object -First 1 } catch { } }
        $olkRun = @(Get-Process olk -ErrorAction SilentlyContinue)
        if ($olk) {
            $forUser = 'n/a'
            try { if ($script:UserSid) { $pui = @($olk.PackageUserInformation | Where-Object { [string]$_.UserSecurityId.Sid -eq $script:UserSid }); $forUser = $(if ($pui.Count) { "installed for user: $($pui[0].InstallState)" } else { 'NOT installed for this user' }) } } catch { }
            W ("New Outlook   : {0}  ({1}; {2})" -f $olk.Version, $forUser, $(if ($olkRun.Count) { "running, $(MBof $olkRun) MB" } else { 'not running' }))
            if ($script:ProfilePath) {
                $mb = Get-FolderSizeMB (Join-Path $script:ProfilePath 'AppData\Local\Packages\Microsoft.OutlookForWindows_8wekyb3d8bbwe')
                if ($null -ne $mb) { W ("  new Outlook local data: {0} MB" -f $mb); if ($mb -gt 3000) { Flag ("New Outlook local data is {0} MB - a reset (Settings > General > Reset) is a common fix for hangs" -f $mb) } }
            }
        } elseif ($olkRun.Count) { W ("New Outlook   : running ({0} MB), version {1}" -f (MBof $olkRun), $(try { (Get-Item $olkRun[0].Path).VersionInfo.ProductVersion } catch { 'n/a' })) } else { W 'New Outlook   : not installed' }
        if ($script:ProfilePath) {
            $ostDir = Join-Path $script:ProfilePath 'AppData\Local\Microsoft\Outlook'
            $stores = @(Get-ChildItem $ostDir -Include '*.ost', '*.pst', '*.nst' -Recurse -File -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 5)
            foreach ($f in $stores) {
                $gb = [math]::Round($f.Length / 1GB, 2)
                W ("Data file     : {0,-38} {1,6} GB  modified {2}" -f (Trunc $f.Name 38), $gb, (Tm $f.LastWriteTime))
                if ($f.Extension -eq '.ost' -and $gb -gt 25) { Flag ("OST '{0}' is {1} GB - expect slow classic Outlook; reduce the cached mail window" -f $f.Name, $gb) }
            }
        }
        $teams = $null; try { $teams = Get-AppxPackage -AllUsers -Name 'MSTeams' -ErrorAction Stop | Select-Object -First 1 } catch { }; if (-not $teams) { try { $teams = Get-AppxPackage -Name 'MSTeams' -ErrorAction Stop | Select-Object -First 1 } catch { } }
        $tRun = @(Get-Process ms-teams -ErrorAction SilentlyContinue)
        W ("Teams (new)   : {0}; {1}" -f $(if ($teams) { $teams.Version } elseif ($tRun.Count) { try { (Get-Item $tRun[0].Path).VersionInfo.ProductVersion + ' (from exe)' } catch { 'version n/a' } } else { 'not installed' }), $(if ($tRun.Count) { "running, $(MBof $tRun) MB" } else { 'not running' }))
        $od = @(Get-Process OneDrive -ErrorAction SilentlyContinue)
        $odVer = 'n/a'
        foreach ($c in @($(if ($script:ProfilePath) { Join-Path $script:ProfilePath 'AppData\Local\Microsoft\OneDrive\OneDrive.exe' }), "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe")) { if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) { try { $odVer = (Get-Item $c).VersionInfo.ProductVersion } catch { }; break } }
        W ("OneDrive      : {0}; {1}" -f $odVer, $(if ($od.Count) { "running, $(MBof $od) MB" } else { 'not running' }))
    }

    # ------------------------------------------------------------- Network
    Section 'Network' {
        $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
        if ($up.Count -eq 0) { W 'NO adapters are up.'; Flag 'No network adapter is connected' }
        foreach ($a in $up) { W ("Adapter up    : {0,-18} {1,-9} {2}  drv {3} ({4})" -f (Trunc $a.Name 18), $a.LinkSpeed, (Trunc $a.InterfaceDescription 38), $a.DriverVersion, $a.DriverDate) }
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
        $gw = $null
        if ($route) {
            $gw = $route.NextHop
            $ad = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            W ("Default route : via {0}{1}  IPv4 {2}/{3}  gw {4}" -f $(if ($ad) { $ad.Name } else { "if$($route.InterfaceIndex)" }), $(if ($ad -and $ad.InterfaceDescription -match 'Wireless|Wi-Fi|802\.11|WLAN') { ' (Wi-Fi)' } else { '' }), $(if ($ip) { $ip.IPAddress } else { '?' }), $(if ($ip) { $ip.PrefixLength } else { '?' }), $gw)
            W ("DNS servers   : {0}" -f $(if ($dnsServers) { $dnsServers -join ', ' } else { 'none' }))
            if ($ip -and $ip.IPAddress -like '169.254.*') { Flag 'Adapter has an APIPA (169.254.x.x) address - DHCP failed' }
            if ($ad) {
                $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction SilentlyContinue
                if ($pm) { W ("NIC power mgmt: allow Windows to turn off device = {0}" -f $pm.AllowComputerToTurnOffDevice) }
            }
        } else { W 'Default route : NONE'; Flag 'No default route (no path to the internet)' }

        $wlanRaw = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -eq 0 -and $wlanRaw -and ($wlanRaw -join '') -notmatch 'no wireless interface') {
            $get = { param($key) $line = $wlanRaw | Where-Object { $_ -match ("^\s*{0}\s*:" -f [regex]::Escape($key)) } | Select-Object -First 1; if ($line) { ($line -split ':', 2)[1].Trim() } else { $null } }
            $state = & $get 'State'
            if ($state -and $state.Trim() -eq 'connected') {
                $sig = & $get 'Signal'
                W ("Wi-Fi         : SSID '{0}'  {1} / ch {2}  {3}  signal {4}  rx/tx {5}/{6} Mbps" -f (& $get 'SSID'), (& $get 'Band'), (& $get 'Channel'), (& $get 'Radio type'), $sig, (& $get 'Receive rate (Mbps)'), (& $get 'Transmit rate (Mbps)'))
                if ($sig -and $sig -match '(\d+)\s*%') { $sigPct = [int]$Matches[1]; if ($sigPct -lt 50) { Flag ("Wi-Fi signal is weak ({0}%) - expect stalls; move closer to the AP or use ethernet" -f $sigPct) } }
            } else { W ("Wi-Fi         : interface present, not connected (state {0})" -f $state) }
            $wlanEv = Get-EventsSafe @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8002, 8003; StartTime = $script:Since }
            W ("Wi-Fi drops   : {0} disconnect / failed-connect event(s) in {1} days" -f $wlanEv.Count, $Days)
            if ($wlanEv.Count -gt 0) {
                $l = $wlanEv | Sort-Object TimeCreated -Descending | Select-Object -First 1
                $reason = ''; if ($l.Message -match 'Reason:\s*(.+)') { $reason = (OneLine $Matches[1]) }
                W ("  latest {0}: {1}" -f (Tm $l.TimeCreated), (Trunc $reason 100))
                if ($wlanEv.Count -ge 5) { Flag ("Wi-Fi disconnected {0} time(s) in {1} days - web apps freeze during reconnects; check driver, AP, roaming" -f $wlanEv.Count, $Days) }
            }
        } else { W 'Wi-Fi         : no wireless interface' }

        $ping = New-Object System.Net.NetworkInformation.Ping
        $targets = @(); if ($gw) { $targets += , @('gateway', $gw) }
        $targets += , @('8.8.8.8', '8.8.8.8'); $targets += , @('outlook.office365.com', 'outlook.office365.com')
        foreach ($t in $targets) {
            $times = @(); $fails = 0
            for ($i = 0; $i -lt 3; $i++) { try { $r = $ping.Send($t[1], 1500); if ($r.Status -eq 'Success') { $times += $r.RoundtripTime } else { $fails++ } } catch { $fails++ } }
            if ($times.Count -gt 0) {
                $avg = [math]::Round(($times | Measure-Object -Average).Average); $max = ($times | Measure-Object -Maximum).Maximum
                W ("Ping {0,-22}: avg {1} ms, max {2} ms{3}" -f $t[0], $avg, $max, $(if ($fails) { " ({0}/3 lost)" -f $fails } else { '' }))
                if ($t[0] -eq 'gateway' -and $avg -gt 100) { Flag ("Gateway latency {0} ms - local network / Wi-Fi problem" -f $avg) }
                if ($fails -gt 0) { Flag ("Packet loss pinging {0}" -f $t[0]) }
            } else { W ("Ping {0,-22}: no reply (ICMP may be blocked for this target)" -f $t[0]) }
        }
        foreach ($h in @('login.microsoftonline.com', 'outlook.office.com', 'outlook.office365.com')) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                $addrs = [System.Net.Dns]::GetHostAddresses($h); $sw.Stop()
                $first = $addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                W ("DNS {0,-24}: {1,5} ms  -> {2}" -f $h, $sw.ElapsedMilliseconds, $first)
                if ($sw.ElapsedMilliseconds -gt 2000) { Flag ("DNS lookup of {0} took {1} ms - slow DNS" -f $h, $sw.ElapsedMilliseconds) }
            } catch { $sw.Stop(); W ("DNS {0,-24}: FAILED" -f $h); Flag ("DNS cannot resolve {0}" -f $h) }
        }
        foreach ($endpointHost in @('login.microsoftonline.com', 'outlook.office.com', 'outlook.office365.com', 'teams.microsoft.com', 'res.cdn.office.net')) {
            $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
            try { $tcp = New-Object System.Net.Sockets.TcpClient; $iar = $tcp.BeginConnect($endpointHost, 443, $null, $null); $ok = $iar.AsyncWaitHandle.WaitOne(4000); if ($ok -and $tcp.Connected) { $tcp.EndConnect($iar) } else { $ok = $false }; $tcp.Close() } catch { $ok = $false }
            $sw.Stop()
            if ($ok) { W ("TCP 443 {0,-24}: OK  {1,5} ms" -f $endpointHost, $sw.ElapsedMilliseconds) } else { W ("TCP 443 {0,-24}: FAIL" -f $endpointHost); Flag ("Cannot reach {0}:443 - connectivity / proxy problem, not an app problem" -f $endpointHost) }
        }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $req = [Net.HttpWebRequest]::Create('https://outlook.office.com/owa/'); $req.AllowAutoRedirect = $false; $req.Timeout = 10000; $req.UserAgent = 'RMM-GrabLogs'
            $code = ''
            try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close() } catch [Net.WebException] { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = "error: $($_.Exception.Status)" } }
            $sw.Stop()
            W ("HTTPS outlook.office.com/owa : status {0} in {1} ms (time to first byte from SYSTEM context)" -f $code, $sw.ElapsedMilliseconds)
            if ($sw.ElapsedMilliseconds -gt 3000) { Flag ("HTTPS round trip to outlook.office.com took {0} ms - slow path (proxy / inspection / link)" -f $sw.ElapsedMilliseconds) }
        } catch { W ("HTTPS outlook.office.com/owa : failed ({0})" -f $_.Exception.Message) }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient('outlook.office.com', 443)
            $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) return $true }
            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
            $ssl.AuthenticateAsClient('outlook.office.com', $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            $cert = $ssl.RemoteCertificate
            $issuer = [string]$cert.Issuer
            $issuerCN = $issuer; if ($issuer -match 'CN=([^,]+)') { $issuerCN = $Matches[1] }
            W ("TLS to outlook.office.com    : {0}, cert issuer '{1}'" -f $ssl.SslProtocol, $issuerCN)
            if ($issuer -notmatch 'Microsoft|DigiCert|Cybertrust|Baltimore|Entrust|GlobalSign|Sectigo|GeoTrust|Thawte|Symantec|VeriSign') { Flag ("TLS to outlook.office.com is terminated by '{0}' - SSL inspection / proxy in the path (Zscaler, Netskope, Umbrella, firewall) - a classic cause of Outlook-web stalls" -f $issuerCN) }
            $ssl.Close(); $tcp.Close()
        } catch { W ("TLS to outlook.office.com    : failed ({0})" -f (Trunc $_.Exception.Message 80)) }
        try { $ncsi = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop; if (([string]$ncsi.Content).Trim() -eq 'Microsoft Connect Test') { W 'NCSI probe    : OK (no captive portal)' } else { W 'NCSI probe    : unexpected content'; Flag 'NCSI probe returned unexpected content - captive portal or intercepting proxy' } } catch { W 'NCSI probe    : FAILED' }

        $winhttp = netsh winhttp show proxy 2>$null
        $direct = ($winhttp -join ' ') -match 'Direct access'
        W ("Proxy (WinHTTP): {0}" -f $(if ($direct) { 'direct' } else { (OneLine (($winhttp | Where-Object { $_ -match 'Proxy Server|Bypass' }) -join ' ')) }))
        if ($script:Hku) {
            $inet = Get-ItemProperty "$($script:Hku)\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
            if ($inet) {
                W ("Proxy (user)  : {0}{1}" -f $(if ($inet.ProxyEnable -eq 1) { "ENABLED -> $($inet.ProxyServer)" } else { 'disabled' }), $(if ($inet.AutoConfigURL) { "; PAC $($inet.AutoConfigURL)" } else { '' }))
                if ($inet.ProxyEnable -eq 1 -and -not $inet.ProxyServer) { Flag 'User proxy is enabled but has no server set' }
            }
        }
        $svcMap = @{ 'ZSAService' = 'Zscaler Client Connector'; 'ZSATunnel' = 'Zscaler tunnel'; 'stAgentSvc' = 'Netskope client'; 'csc_umbrellaagent' = 'Cisco Umbrella'; 'Umbrella_RC' = 'Cisco Umbrella'; 'CloudflareWARP' = 'Cloudflare WARP'; 'PanGPS' = 'Palo Alto GlobalProtect'; 'vpnagent' = 'Cisco AnyConnect'; 'csc_vpnagent' = 'Cisco Secure Client VPN'; 'FA_Scheduler' = 'FortiClient'; 'PulseSecureService' = 'Ivanti / Pulse'; 'TracSrvWrapper' = 'Check Point'; 'WireGuardManager' = 'WireGuard'; 'OpenVPNService' = 'OpenVPN'; 'Tailscale' = 'Tailscale'; 'ZeroTierOneService' = 'ZeroTier'; 'SGNAgent' = 'Todyl SGN'; 'Twingate.Service' = 'Twingate' }
        $found = @()
        foreach ($k in ($svcMap.Keys | Sort-Object)) { $s = Get-Service -Name $k -ErrorAction SilentlyContinue; if ($s) { $found += ("{0} [{1}]" -f $svcMap[$k], $s.Status) } }
        $vpnAd = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'PANGP|AnyConnect|Cisco Secure|Fortinet|FortiSSL|Pulse|WireGuard|OpenVPN|TAP-Windows|Tailscale|ZeroTier|Check Point|Zscaler|Netskope|Umbrella|Cloudflare|Twingate|Todyl' })
        foreach ($va in $vpnAd) { $found += ("adapter '{0}' {1}" -f (Trunc $va.InterfaceDescription 30), $va.Status) }
        try { foreach ($b in @(Get-VpnConnection -AllUserConnection -ErrorAction Stop) + @(Get-VpnConnection -ErrorAction Stop)) { $found += ("Windows VPN '{0}' {1}" -f $b.Name, $b.ConnectionStatus) } } catch { }
        W ("VPN / SASE    : {0}" -f $(if ($found.Count) { $found -join '; ' } else { 'none detected' }))
    }

    # ---------------------------------------------------- Security agents
    Section 'Security agents' {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            W ("Defender      : mode {0}; real-time {1}; signatures {2} ({3})" -f $mp.AMRunningMode, $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureVersion, (Tm $mp.AntivirusSignatureLastUpdated 'yyyy-MM-dd'))
            if ($mp.AMRunningMode -eq 'Normal' -and $mp.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-7)) { Flag 'Defender signatures are more than 7 days old' }
        } catch { W 'Defender      : n/a' }
        $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
        if ($av.Count) { W ("AV registered : {0}" -f (($av | ForEach-Object { "{0} (state 0x{1:X})" -f $_.displayName, $_.productState }) -join '; ')) }
        $agents = @{ 'SentinelAgent' = 'SentinelOne'; 'CSFalconService' = 'CrowdStrike Falcon'; 'ekrn' = 'ESET'; 'Sophos Endpoint Defense Service' = 'Sophos'; 'cyserver' = 'Cortex XDR'; 'CbDefense' = 'Carbon Black'; 'HuntressAgent' = 'Huntress'; 'MBAMService' = 'Malwarebytes'; 'WRSVC' = 'Webroot'; 'ThreatLockerService' = 'ThreatLocker'; 'AutoElevateAgent' = 'CyberFOX AutoElevate'; 'Sense' = 'Defender for Endpoint sensor'; 'AteraAgent' = 'Atera agent'; 'SplashtopRemoteService' = 'Splashtop'; 'ZSAService' = 'Zscaler Client Connector'; 'stAgentSvc' = 'Netskope'; 'csc_umbrellaagent' = 'Cisco Umbrella'; 'IntuneManagementExtension' = 'Intune Management Extension'; 'BESClient' = 'BigFix'; 'ScreenConnect Client*' = 'ScreenConnect'; 'ninjarmm-agent' = 'NinjaOne' }
        $n = 0
        foreach ($k in ($agents.Keys | Sort-Object)) { foreach ($s in @(Get-Service -Name $k -ErrorAction SilentlyContinue)) { $n++; W ("  {0,-30} {1,-8} ({2})" -f $agents[$k], $s.Status, $s.Name) } }
        if ($n -eq 0) { W '  no known third-party agents found' }
    }

    # ------------------------------ Recent installs / startup / Windows Update
    Section 'Recent installs (30 days) / startup / Windows Update' {
        $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        if ($script:Hku) { $roots += "$($script:Hku)\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
        $allApps = foreach ($r in $roots) { foreach ($k in @(Get-ChildItem $r -ErrorAction SilentlyContinue)) { $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue; if ($p -and $p.DisplayName) { $dt = $null; if ($p.InstallDate -match '^\d{8}$') { try { $dt = [datetime]::ParseExact($p.InstallDate, 'yyyyMMdd', $null) } catch { } }; New-Object psobject -Property @{ Date = $dt; Name = [string]$p.DisplayName; Ver = [string]$p.DisplayVersion } } } }
        $recent = @($allApps | Where-Object { $_.Date -and $_.Date -gt (Get-Date).AddDays(-30) } | Sort-Object Date -Descending | Select-Object -First 15)
        W ("Installed / updated programs in last 30 days: {0}" -f $recent.Count)
        foreach ($x in $recent) { W ("  {0}  {1} {2}" -f (Tm $x.Date 'MM/dd'), (Trunc $x.Name 50), (Trunc $x.Ver 20)) }
        $oem = @($allApps | Where-Object { $_.Name -match '^(Lenovo|Dell|HP |HP$|Intel\(R\) Driver|AMD Software|Realtek|Dolby|Synaptics|ELAN)' } | Select-Object -ExpandProperty Name -Unique | Select-Object -First 10)
        $oemApp = @(); try { $oemApp = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.Name -match 'Lenovo|DellInc|HPInc|AD2F1837|AMD|RealtekSemi|DolbyLaboratories' } | Select-Object -ExpandProperty Name -Unique | Select-Object -First 8) } catch { }
        W ("OEM / vendor utilities: {0}" -f $(if ($oem.Count + $oemApp.Count) { (Trunc (($oem + $oemApp) -join '; ') 300) } else { 'none' }))
        $runKeys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
        if ($script:Hku) { $runKeys += "$($script:Hku)\Software\Microsoft\Windows\CurrentVersion\Run" }
        $startup = @(foreach ($k in $runKeys) { $p = Get-ItemProperty $k -ErrorAction SilentlyContinue; if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $_.Name } } })
        foreach ($d in @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp", $(if ($script:ProfilePath) { Join-Path $script:ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }))) { if ($d -and (Test-Path $d -ErrorAction SilentlyContinue)) { $startup += @(Get-ChildItem $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.BaseName }) } }
        W ("Startup items : {0}  [{1}]" -f $startup.Count, (Trunc (($startup | Select-Object -First 15) -join ', ') 220))
        $qfe = Get-CimInstance Win32_QuickFixEngineering -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($qfe) { W ("Latest hotfix : {0} on {1}" -f $qfe.HotFixID, (Tm $qfe.InstalledOn 'yyyy-MM-dd')) }
        try {
            $srch = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $n = $srch.GetTotalHistoryCount()
            $hist = $srch.QueryHistory(0, [math]::Min($n, 40))
            $rows = @(); foreach ($h in $hist) { if ($h.Operation -eq 1 -and $h.Title) { $rows += New-Object psobject -Property @{ Date = $h.Date; Title = [string]$h.Title; Result = [int]$h.ResultCode } } }
            W 'Windows Update history (installs, newest first):'
            foreach ($r in ($rows | Sort-Object Date -Descending | Select-Object -First 8)) {
                $res = switch ($r.Result) { 2 { 'OK' } 3 { 'OK-partial' } 4 { 'FAILED' } 5 { 'aborted' } default { "code $($r.Result)" } }
                W ("  {0}  {1,-10} {2}" -f (Tm $r.Date 'MM/dd'), $res, (Trunc $r.Title 80))
                if ($r.Result -eq 4 -and $r.Date -gt $script:Since) { Flag ("Windows Update install FAILED on {0}: {1}" -f (Tm $r.Date 'MM/dd'), (Trunc $r.Title 60)) }
                if ($r.Date -gt $script:Since -and $r.Title -match '\b(driver|firmware|AMD|Intel|NVIDIA|Realtek|Lenovo|Dell|HP|Qualcomm|MediaTek|DisplayLink|Synaptics)\b' -and $r.Title -notmatch 'Security Intelligence|Defender') { W ("      ^ driver/firmware delivered by WU inside the window - correlate with when the symptom started") }
            }
        } catch { W 'Windows Update history: n/a' }
    }

    # --------------------------------------------------------- Key drivers
    Section 'Key drivers (display / network / audio / storage / bluetooth)' {
        $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -in @('DISPLAY', 'NET', 'MEDIA', 'SCSIADAPTER', 'HDC', 'BLUETOOTH') -and $_.DeviceName -and $_.DriverVersion -and $_.DeviceName -notmatch 'WAN Miniport|Kernel Debug|Teredo|ISATAP|Wi-Fi Direct Virtual|Hyper-V|Npcap|TAP-Windows|Microsoft ISATAP|Bluetooth Device \(|Microsoft Bluetooth' })
        foreach ($d in ($drv | Sort-Object DeviceClass, DeviceName -Unique | Select-Object -First 16)) {
            W ("  {0,-11} {1,-44} {2,-16} {3}  {4}" -f $d.DeviceClass, (Trunc $d.DeviceName 44), $d.DriverVersion, (Tm $d.DriverDate 'yyyy-MM-dd'), (Trunc $d.DriverProviderName 18))
        }
        if ($drv.Count -eq 0) { W '  n/a' }
    }

    # ------------------------------------------------- Recent error digest
    Section ("Recent error digest - last {0} days" -f $Days) {
        $noise = 'DistributedCOM|Perflib|Security-SPP|SideBySide|Microsoft-Windows-WMI|User Device Registration|Microsoft-Windows-AAD|ESENT|Software Protection|Windows Search|SearchIndexer|Microsoft-Windows-CAPI2|SecurityCenter|AppModel-Runtime|TWinUI|Immersive-Shell|AppXDeployment|AppReadiness|Kernel-EventTracing|PushNotifications|LanguageComponentsInstaller|Microsoft-Windows-Store|Microsoft-Windows-Bits-Client|EventSystem|Microsoft-Windows-DeviceSetupManager|Microsoft-Windows-Time-Service|Microsoft-Windows-Kernel-Boot|Microsoft-Windows-Winlogon|Microsoft-Windows-RestartManager'
        $errs = @((Get-EventsSafe @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $script:Since } 1500) | Where-Object { $_.ProviderName -notmatch $noise -and -not ($_.ProviderName -in @('Application Error', 'Application Hang', 'Windows Error Reporting')) })
        $groups = @($errs | Group-Object { "{0}|{1}|{2}" -f $_.LogName, $_.ProviderName, $_.Id } | ForEach-Object {
            $l = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
            New-Object psobject -Property @{ Latest = $l.TimeCreated; Count = $_.Count; Log = $l.LogName; Provider = $l.ProviderName; Id = $l.Id; Msg = $(if ($l.Message) { OneLine $l.Message } else { '(no message text)' }) }
        })
        W ("{0} error / critical event(s) after noise filtering; {1} distinct (provider, id) pairs - newest first, max {2}:" -f $errs.Count, $groups.Count, $EventLines)
        foreach ($g in ($groups | Sort-Object Latest -Descending | Select-Object -First $EventLines)) {
            W ("  {0}  x{1,-3} {2,-3} {3} {4}" -f (Tm $g.Latest), $g.Count, $(if ($g.Log -eq 'System') { 'SYS' } else { 'APP' }), $g.Provider, $g.Id)
            W ("      {0}" -f (Trunc $g.Msg 150))
        }
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
