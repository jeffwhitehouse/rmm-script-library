<#
================================================================================
  RMM Script Library - Repair-Network
================================================================================
  PURPOSE : First-line network fix for "internet is broken / VPN won't
            connect" after Test-NetworkHealth showed a local problem.
            Flush DNS -> renew DHCP -> verify. -Deep adds adapter restart
            and a full winsock/IP-stack reset (needs a reboot to finish).

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 5 minutes

  MODES   : (no switch)  REPORT-ONLY - quick check + what -Fix would do.
            -Fix         flush DNS + renew DHCP on the active adapter, retest.
            -Fix -Deep   also restart the adapter, then winsock + IP stack
                         reset (flags that a reboot is required).
                         (-Deep alone implies -Fix.)

  NOTE    : The machine may drop off the network for a few seconds mid-run;
            the script keeps running locally and uploads results when done.

  EXIT CODES:  0 = OK   1 = needs attention   2 = script/context error

  VERSION : 0.1-DEV (2026-07-21)
================================================================================
#>
param([switch]$Fix, [switch]$Deep)

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        $extra = @()
        if ($Fix)  { $extra += '-Fix' }
        if ($Deep) { $extra += '-Deep' }
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath @extra
        exit $LASTEXITCODE
    }
}

if ($Deep) { $Fix = $true }

$ScriptName    = 'Repair-Network'
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

# Result is passed via $script:LastBasicsOk, NOT a return value: W emits to the
# output stream, so a "return" here would be captured by the caller's assignment
# and the section would vanish from stdout.
function Test-Basics {
    param([string]$Label)
    Sect ("Connectivity check - {0}" -f $Label)
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $ok = $true
    if (-not $route) {
        W '  No default route.'
        $script:LastBasicsOk = $false
        return
    }
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $r = $ping.Send($route.NextHop, 1500)
        if ($r.Status -eq 'Success') { W ("  Gateway ping : {0} ms" -f $r.RoundtripTime) }
        else { W ("  Gateway ping : {0}" -f $r.Status); $ok = $false }
    } catch { W '  Gateway ping : error'; $ok = $false }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        [System.Net.Dns]::GetHostAddresses('login.microsoftonline.com') | Out-Null
        $sw.Stop()
        W ("  DNS resolve  : login.microsoftonline.com OK ({0} ms)" -f $sw.ElapsedMilliseconds)
    } catch {
        $sw.Stop()
        W '  DNS resolve  : login.microsoftonline.com FAILED'
        $ok = $false
    }
    $script:LastBasicsOk = $ok
}

try {
    W ('=' * 64)
    W (" {0}  v{1}   mode: {2}" -f $ScriptName, $ScriptVersion, $(if ($Deep) { 'FIX+DEEP' } elseif ($Fix) { 'FIX' } else { 'REPORT-ONLY (run with -Fix to apply)' }))
    W ('=' * 64)
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f $ident.Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # ---- Context guard: fixes need SYSTEM/admin ----
    $isAdmin = ([Security.Principal.WindowsPrincipal]$ident).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Fix -and -not $isAdmin) {
        W ''
        W 'WRONG RUN-AS CONTEXT.'
        W 'Network repair needs System rights. In the RMM, re-run it with'
        W 'Run As: System (the default).'
        W ''
        W 'RESULT: SCRIPT-ERROR (wrong context - nothing was changed)'
        Save-Log
        exit 2
    }

    # ---------------- Current state ----------------
    Sect 'Adapters (up)'
    $upAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    foreach ($a in $upAdapters) { W ("  {0,-24} {1,-10} {2}" -f $a.Name, $a.LinkSpeed, $a.InterfaceDescription) }
    if ($upAdapters.Count -eq 0) {
        W '  NONE - no adapter is connected.'
        Flag 'No network adapter is up - check cable/Wi-Fi/airplane mode; script cannot fix layer 1'
    }

    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $adName = $null; $dhcpOn = $false
    if ($route) {
        $ad = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if ($ad) { $adName = $ad.Name }
        $ipIf = Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipIf) { $dhcpOn = ($ipIf.Dhcp -eq 'Enabled') }
        W ("Default-route adapter : {0} (DHCP {1})" -f $adName, $(if ($dhcpOn) { 'enabled' } else { 'DISABLED - static IP, renew will be skipped' }))
    } else {
        W 'Default-route adapter : none (no default route)'
    }

    Test-Basics 'before'
    $beforeOk = $script:LastBasicsOk

    # ---------------- Report-only stops here ----------------
    if (-not $Fix) {
        Sect 'Planned actions (re-run with -Fix to apply)'
        W '  1. Flush DNS resolver cache'
        if ($dhcpOn -and $adName) { W ("  2. Release/renew DHCP on '{0}' (brief network drop)" -f $adName) }
        W '  With -Deep additionally:'
        if ($adName) { W ("  3. Restart adapter '{0}' (~10s drop)" -f $adName) }
        W '  4. netsh winsock reset + netsh int ip reset (REBOOT required after)'
        if (-not $beforeOk) { Flag 'Connectivity problems confirmed - re-run with -Fix' }
        Finish
    }

    # ---------------- Fix ----------------
    Sect 'Applying fixes'
    W 'Flushing DNS cache...'
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    W '  done.'

    if ($Deep -and $adName) {
        W ("Restarting adapter '{0}'..." -f $adName)
        Restart-NetAdapter -Name $adName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
        $adNow = Get-NetAdapter -Name $adName -ErrorAction SilentlyContinue
        W ("  adapter status now: {0}" -f $(if ($adNow) { $adNow.Status } else { 'unknown' }))
        if ($adNow -and $adNow.Status -ne 'Up') { Flag ("Adapter '{0}' did not come back Up after restart" -f $adName) }
    }

    if ($dhcpOn -and $adName) {
        W ("Renewing DHCP lease on '{0}'..." -f $adName)
        ipconfig /release "$adName" | Out-Null
        Start-Sleep -Seconds 2
        ipconfig /renew "$adName" | Out-Null
        Start-Sleep -Seconds 3
        $newIp = Get-NetIPAddress -InterfaceAlias $adName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        W ("  new IPv4: {0}" -f $(if ($newIp) { $newIp.IPAddress } else { 'NONE' }))
        if (-not $newIp -or $newIp.IPAddress -like '169.254.*') { Flag 'DHCP renew did not produce a valid lease - DHCP server/VLAN problem upstream' }
    } elseif (-not $dhcpOn) {
        W 'Static IP configuration - DHCP renew skipped.'
    }

    Test-Basics 'after'
    $afterOk = $script:LastBasicsOk

    if ($Deep) {
        Sect 'Deep reset (winsock + IP stack)'
        netsh winsock reset | Out-Null
        W ("  winsock reset : exit {0}" -f $LASTEXITCODE)
        netsh int ip reset | Out-Null
        W ("  ip stack reset: exit {0}" -f $LASTEXITCODE)
        Flag 'Deep reset applied - REBOOT the machine to complete the network stack reset'
    }

    Sect 'Outcome'
    W ("Before fix : {0}" -f $(if ($beforeOk) { 'connectivity OK' } else { 'connectivity BROKEN' }))
    W ("After fix  : {0}" -f $(if ($afterOk) { 'connectivity OK' } else { 'connectivity still BROKEN' }))
    if (-not $afterOk) {
        Flag 'Connectivity still failing after fixes - likely upstream (switch/AP/ISP/VPN gateway) or hardware; needs hands-on'
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
