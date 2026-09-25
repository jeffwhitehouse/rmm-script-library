<#
================================================================================
  RMM Script Library - Get-M365Health
================================================================================
  PURPOSE : Outlook / Teams / M365 sign-in triage without remoting in.
            Read-only. Finds the usual suspects behind "Outlook is broken",
            "Teams won't load", "can't sign in":
            huge/stale OST, crashed add-ins, disabled items, classic-Teams
            remnants, bloated Teams cache, time skew, Entra PRT problems,
            blocked M365 endpoints, recent Outlook/Teams crash events.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 10 minutes (cache-size measurement can take a moment)

  NOTE ON SYSTEM CONTEXT:
    The RMM runs this as SYSTEM. The script locates the logged-on user and reads
    their hive/profile directly. One thing SYSTEM cannot see is the USER's
    Entra PRT (dsregcmd only shows it in the user's own context) - the script
    compensates by checking the AAD operational event log for recent errors.

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

$ScriptName    = 'Get-M365Health'
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
    W (" {0}  v{1}" -f $ScriptName, $ScriptVersion)
    W ('=' * 64)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f $me)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # ---------------- Locate the logged-on user ----------------
    Sect 'Logged-on user'
    $userDomain = $null; $userName = $null
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer) {
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) { $userDomain = $owner.Domain; $userName = $owner.User }
    }
    if (-not $userName) {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.UserName) {
            $parts = $cs.UserName -split '\\', 2
            if ($parts.Count -eq 2) { $userDomain = $parts[0]; $userName = $parts[1] }
        }
    }
    if (-not $userName) {
        W 'No interactive user is logged on - user-profile checks skipped.'
        Flag 'No user logged on; re-run while the user is signed in for full results'
        Finish
    }

    $fullUser = "$userDomain\$userName"
    $sid = $null; $profilePath = $null
    try {
        $sid = (New-Object Security.Principal.NTAccount($userDomain, $userName)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profilePath = (Get-ItemProperty ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}" -f $sid) -ErrorAction Stop).ProfileImagePath
    } catch { }
    W ("User          : {0}" -f $fullUser)
    W ("SID           : {0}" -f $(if ($sid) { $sid } else { 'n/a' }))
    W ("Profile       : {0}" -f $(if ($profilePath) { $profilePath } else { 'n/a' }))
    if (-not $profilePath) {
        Flag 'Could not resolve user profile path - remaining checks limited'
        Finish
    }
    $hku = "Registry::HKEY_USERS\$sid"
    $hiveLoaded = Test-Path $hku
    W ("User hive     : {0}" -f $(if ($hiveLoaded) { 'loaded (readable)' } else { 'NOT loaded' }))

    # ---------------- Office install ----------------
    Sect 'Office (Click-to-Run)'
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r) {
        $channelMap = @{
            '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
            '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
            '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
            '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
            'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise (Preview)'
            '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
        }
        $chan = [string]$c2r.UpdateChannel
        $chanName = $chan
        foreach ($k in $channelMap.Keys) { if ($chan -match $k) { $chanName = $channelMap[$k] } }
        W ("Version       : {0}" -f $c2r.VersionToReport)
        W ("Channel       : {0}" -f $chanName)
        W ("Products      : {0}" -f $c2r.ProductReleaseIds)
    } else {
        W 'No Click-to-Run Office found.'
        Flag 'Office Click-to-Run not detected on this machine'
    }

    # ---------------- Outlook ----------------
    Sect 'Outlook'
    $olRunning = @(Get-Process OUTLOOK -ErrorAction SilentlyContinue).Count -gt 0
    W ("Outlook running   : {0}" -f $(if ($olRunning) { 'yes' } else { 'no' }))

    if ($hiveLoaded) {
        $profRoot = "$hku\Software\Microsoft\Office\16.0\Outlook\Profiles"
        $profNames = @()
        if (Test-Path $profRoot) { $profNames = @(Get-ChildItem $profRoot -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName }) }
        $defProf = $null
        try { $defProf = (Get-ItemProperty "$hku\Software\Microsoft\Office\16.0\Outlook" -ErrorAction Stop).DefaultProfile } catch { }
        W ("Mail profiles     : {0} ({1})" -f $profNames.Count, $(if ($profNames.Count) { $profNames -join ', ' } else { 'none' }))
        if ($defProf) { W ("Default profile   : {0}" -f $defProf) }
        if ($profNames.Count -eq 0) { Flag 'No Outlook mail profile exists for this user' }

        # Disabled items / crashing add-ins (Outlook resiliency)
        foreach ($resil in @(
            @('Disabled items', "$hku\Software\Microsoft\Office\16.0\Outlook\Resiliency\DisabledItems"),
            @('Crashing addins', "$hku\Software\Microsoft\Office\16.0\Outlook\Resiliency\CrashingAddinList")
        )) {
            $cnt = 0
            if (Test-Path $resil[1]) { $cnt = @((Get-Item $resil[1] -ErrorAction SilentlyContinue).Property).Count }
            W ("{0,-18}: {1}" -f $resil[0], $cnt)
            if ($cnt -gt 0) { Flag ("Outlook has {0} entry(ies) under '{1}' - an add-in was disabled/crashing" -f $cnt, $resil[0]) }
        }

        # Add-in load behavior (user + machine)
        $badAddins = @()
        foreach ($root in @("$hku\Software\Microsoft\Office\Outlook\Addins", 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins')) {
            if (Test-Path $root) {
                Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
                    $lb = $null
                    try { $lb = (Get-ItemProperty $_.PSPath -ErrorAction Stop).LoadBehavior } catch { }
                    if ($null -ne $lb -and $lb -ne 3 -and $lb -ne 9 -and $lb -ne 16) {
                        $badAddins += ("{0} (LoadBehavior={1})" -f $_.PSChildName, $lb)
                    }
                }
            }
        }
        if ($badAddins.Count -gt 0) {
            W 'Add-ins not set to auto-load (LoadBehavior <> 3):'
            $badAddins | Select-Object -First 6 | ForEach-Object { W ("  {0}" -f $_) }
        } else {
            W 'Add-ins           : all registered add-ins set to auto-load'
        }
    } else {
        W 'User hive not loaded - profile/add-in registry checks skipped.'
    }

    # OST / PST files
    $ostDir = Join-Path $profilePath 'AppData\Local\Microsoft\Outlook'
    if (Test-Path $ostDir) {
        $stores = @(Get-ChildItem $ostDir -Include '*.ost', '*.pst', '*.nst' -Recurse -File -ErrorAction SilentlyContinue)
        if ($stores.Count -gt 0) {
            W 'Data files:'
            foreach ($f in ($stores | Sort-Object Length -Descending)) {
                $gb = [math]::Round($f.Length / 1GB, 2)
                W ("  {0,-40} {1,8} GB  modified {2}" -f $f.Name, $gb, $f.LastWriteTime.ToString('MM/dd HH:mm'))
                if ($f.Extension -eq '.ost' -and $gb -gt 25) { Flag ("OST '{0}' is {1} GB - expect slow Outlook; consider reducing cached mail window" -f $f.Name, $gb) }
                if ($f.Extension -eq '.ost' -and $olRunning -and $f.LastWriteTime -lt (Get-Date).AddDays(-2)) { Flag ("OST '{0}' not written in 2+ days while Outlook runs - possible sync stall" -f $f.Name) }
            }
        } else { W 'Data files: none found' }
    } else {
        W ("Data files: folder not found ({0})" -f $ostDir)
    }

    # ---------------- Teams ----------------
    Sect 'Teams'
    $teamsRunning = @(Get-Process ms-teams -ErrorAction SilentlyContinue).Count -gt 0
    W ("Teams running     : {0}" -f $(if ($teamsRunning) { 'yes' } else { 'no' }))
    $newTeams = $null
    try { $newTeams = Get-AppxPackage -Name 'MSTeams' -ErrorAction Stop } catch { }
    if (-not $newTeams) { try { $newTeams = Get-AppxPackage -AllUsers -Name 'MSTeams' -ErrorAction Stop | Select-Object -First 1 } catch { } }
    if ($newTeams) { W ("New Teams         : {0}" -f $newTeams.Version) }
    else {
        W 'New Teams         : NOT installed'
        Flag 'New Teams (MSTeams package) not found for this machine/user'
    }
    $newCache = Join-Path $profilePath 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe'
    $newCacheMB = Get-FolderSizeMB $newCache
    if ($null -ne $newCacheMB) {
        W ("New Teams data    : {0} MB" -f $newCacheMB)
        if ($newCacheMB -gt 4096) { Flag ("New Teams local data is {0} MB - cache reset is the usual fix for load/blank-screen issues" -f $newCacheMB) }
    }
    $classic = Join-Path $profilePath 'AppData\Roaming\Microsoft\Teams'
    if (Test-Path $classic) {
        $classicMB = Get-FolderSizeMB $classic
        W ("Classic Teams     : remnant present ({0} MB in AppData\Roaming\Microsoft\Teams)" -f $classicMB)
        if ($classicMB -gt 500) { Flag ("Classic Teams remnant is {0} MB - safe to clean up" -f $classicMB) }
    } else {
        W 'Classic Teams     : no remnants'
    }

    # ---------------- OneDrive ----------------
    Sect 'OneDrive'
    $odRunning = @(Get-Process OneDrive -ErrorAction SilentlyContinue).Count -gt 0
    W ("OneDrive running  : {0}" -f $(if ($odRunning) { 'yes' } else { 'no' }))
    $odExe = Join-Path $profilePath 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'
    if (-not (Test-Path $odExe)) { $odExe = "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe" }
    if (Test-Path $odExe) {
        try { W ("OneDrive version  : {0}" -f (Get-Item $odExe).VersionInfo.ProductVersion) } catch { }
    }
    if (-not $odRunning) { Flag 'OneDrive is not running - files will not sync for this user' }

    # ---------------- Sign-in / Entra ----------------
    Sect 'Sign-in / Entra'
    try {
        $ds = & "$env:WINDIR\System32\dsregcmd.exe" /status 2>$null
        foreach ($k in 'AzureAdJoined', 'DomainJoined', 'TenantName') {
            $line = $ds | Where-Object { $_ -match ("^\s*{0}\s*:" -f $k) } | Select-Object -First 1
            if ($line) { W ($line.Trim()) }
        }
        if ($me -like "*$userName") {
            foreach ($k in 'AzureAdPrt', 'AzureAdPrtUpdateTime') {
                $line = $ds | Where-Object { $_ -match ("^\s*{0}\s*:" -f $k) } | Select-Object -First 1
                if ($line) { W ($line.Trim()) }
            }
            $prtNo = $ds | Where-Object { $_ -match '^\s*AzureAdPrt\s*:\s*NO' }
            if ($prtNo) { Flag 'AzureAdPrt: NO - user has no Primary Refresh Token; M365 sign-in will fail or loop (fix: lock/unlock, then reboot; check time skew below)' }
        } else {
            W 'AzureAdPrt        : not visible from SYSTEM - if sign-in issues persist, re-run in user context'
        }
    } catch { W 'dsregcmd not available.' }

    # AAD operational log errors - INFORMATIONAL ONLY. Healthy Entra-joined
    # machines log dozens of these (token-broker noise: 1025/1098/1104);
    # verified on a machine with a fresh PRT. PRT state is the real signal.
    $aadErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AAD/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 50 -ErrorAction SilentlyContinue)
    W ("AAD log errors (3d): {0} (routine noise is normal; only meaningful alongside PRT=NO)" -f $aadErr.Count)
    if ($aadErr.Count -gt 0) {
        $topAad = $aadErr | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3
        foreach ($g in $topAad) { W ("  event {0} x{1}" -f $g.Name, $g.Count) }
    }

    # Time sync (skew breaks token issuance)
    $w32 = w32tm /query /status 2>$null
    if ($LASTEXITCODE -eq 0 -and $w32) {
        foreach ($k in 'Source', 'Last Successful Sync Time') {
            $line = $w32 | Where-Object { $_ -match ("^{0}\s*:" -f [regex]::Escape($k)) } | Select-Object -First 1
            if ($line) { W ($line.Trim()) }
        }
    }
    $skewLine = w32tm /stripchart /computer:time.windows.com /samples:1 /dataonly 2>$null | Select-Object -Last 1
    if ($skewLine -and $skewLine -match '([+-]\d+\.\d+)s') {
        $skew = [math]::Abs([double]$Matches[1])
        W ("Clock skew vs time.windows.com: {0}s" -f [math]::Round($skew, 2))
        if ($skew -gt 90) { Flag ("Clock is off by {0}s - breaks M365/Kerberos sign-in; resync time" -f [int]$skew) }
    } else {
        W 'Clock skew: n/a (NTP probe blocked or offline)'
    }

    # ---------------- M365 endpoint reachability ----------------
    Sect 'M365 endpoint reachability (TCP 443)'
    foreach ($endpointHost in @('login.microsoftonline.com', 'outlook.office365.com', 'teams.microsoft.com', 'graph.microsoft.com')) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ok = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($endpointHost, 443, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(4000)
            if ($ok -and $tcp.Connected) { $tcp.EndConnect($iar) } else { $ok = $false }
            $tcp.Close()
        } catch { $ok = $false }
        $sw.Stop()
        if ($ok) { W ("  {0,-28} OK   {1,5} ms" -f $endpointHost, $sw.ElapsedMilliseconds) }
        else {
            W ("  {0,-28} FAIL" -f $endpointHost)
            Flag ("Cannot reach {0}:443 - connectivity/proxy problem, not an Outlook problem" -f $endpointHost)
        }
    }

    # ---------------- Recent Outlook/Teams/OneDrive crashes ----------------
    Sect 'App crash events (7 days)'
    $since = (Get-Date).AddDays(-7)
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = $since } -ErrorAction SilentlyContinue)
    $watch = @('OUTLOOK.EXE', 'ms-teams.exe', 'OneDrive.exe', 'EXCEL.EXE', 'WINWORD.EXE')
    $found = $false
    foreach ($app in $watch) {
        $n = @($crashes | Where-Object {
            try { $_.Properties.Count -gt 0 -and ([string]$_.Properties[0].Value) -ieq $app } catch { $false }
        }).Count
        if ($n -gt 0) {
            $found = $true
            W ("  {0,-16} x{1}" -f $app, $n)
            Flag ("{0} crashed/hung {1} time(s) in 7 days" -f $app, $n)
        }
    }
    if (-not $found) { W '  none for Outlook / Teams / OneDrive / Excel / Word' }

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
