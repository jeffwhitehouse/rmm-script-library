<#
================================================================================
  RMM Script Library - Test-NetworkHealth
================================================================================
  PURPOSE : Full connectivity / Wi-Fi / VPN triage. Read-only.
            Answers "is it the network, the VPN, DNS, the proxy, or the app"
            for slow/no-internet and VPN tickets - including whether the
            RMM agent itself can resolve its API (set $RmmApiHost below;
            if that name stops resolving, the agent silently drops offline).

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

$ScriptName    = 'Test-NetworkHealth'
$ScriptVersion = '0.1-DEV'
$ErrorActionPreference = 'Continue'

# Hosts every managed endpoint should resolve + reach. Add internal names
# (ticketing system, file servers) here or inject via RMM script variables.
# $RmmApiHost: your RMM agent's cloud API hostname; leave empty to skip.
$RmmApiHost = ''
$DnsTargets = @('login.microsoftonline.com', 'outlook.office365.com') + @($RmmApiHost | Where-Object { $_ })
$Tcp443Targets = @('login.microsoftonline.com', 'outlook.office365.com', 'teams.microsoft.com') + @($RmmApiHost | Where-Object { $_ })

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

    # ---------------- Adapters ----------------
    Sect 'Adapters (up)'
    $upAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    if ($upAdapters.Count -eq 0) {
        W 'NO adapters are up.'
        Flag 'No network adapter is connected'
    }
    foreach ($a in $upAdapters) {
        W ("  {0,-24} {1,-10} {2}" -f $a.Name, $a.LinkSpeed, $a.InterfaceDescription)
    }

    # ---------------- Wi-Fi detail ----------------
    Sect 'Wi-Fi'
    $wlanRaw = netsh wlan show interfaces 2>$null
    $wifiConnected = $false
    if ($LASTEXITCODE -eq 0 -and $wlanRaw -and ($wlanRaw -join '') -notmatch 'no wireless interface') {
        $get = {
            param($key)
            $line = $wlanRaw | Where-Object { $_ -match ("^\s*{0}\s*:" -f [regex]::Escape($key)) } | Select-Object -First 1
            if ($line) { ($line -split ':', 2)[1].Trim() } else { $null }
        }
        $state = & $get 'State'
        if ($state -and $state.Trim() -eq 'connected') {
            $wifiConnected = $true
            W ("  State        : {0}" -f $state)
            W ("  SSID         : {0}" -f (& $get 'SSID'))
            W ("  Band/Channel : {0} / {1}" -f (& $get 'Band'), (& $get 'Channel'))
            W ("  Radio        : {0}" -f (& $get 'Radio type'))
            $sig = & $get 'Signal'
            W ("  Signal       : {0}" -f $sig)
            W ("  Rx/Tx rate   : {0} / {1} Mbps" -f (& $get 'Receive rate (Mbps)'), (& $get 'Transmit rate (Mbps)'))
            if ($sig -and $sig -match '(\d+)\s*%') {
                $sigPct = [int]$Matches[1]
                if ($sigPct -lt 50) { Flag ("Wi-Fi signal is weak ({0}%) - expect drops/slowness; move closer to AP or dock to ethernet" -f $sigPct) }
            }
        } else {
            W ("  Wireless interface present but not connected (state: {0})" -f $state)
        }
    } else {
        W '  No wireless interface (or WLAN service not running).'
    }

    # ---------------- IP configuration ----------------
    Sect 'IP configuration (default-route adapter)'
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $gw = $null
    if ($route) {
        $gw = $route.NextHop
        $ifIdx = $route.InterfaceIndex
        $ad = Get-NetAdapter -InterfaceIndex $ifIdx -ErrorAction SilentlyContinue
        $ip = Get-NetIPAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($ad) { W ("  Adapter    : {0}" -f $ad.Name) }
        if ($ip) { W ("  IPv4       : {0}/{1}" -f $ip.IPAddress, $ip.PrefixLength) }
        W ("  Gateway    : {0}" -f $gw)
        W ("  DNS servers: {0}" -f $(if ($dnsServers) { $dnsServers -join ', ' } else { 'none' }))
        if ($ip -and $ip.IPAddress -like '169.254.*') { Flag 'Adapter has an APIPA (169.254.x.x) address - DHCP failed' }
    } else {
        W '  No default route.'
        Flag 'No default route (no path to the internet)'
    }

    # ---------------- Latency ----------------
    Sect 'Latency (2 pings each)'
    $ping = New-Object System.Net.NetworkInformation.Ping
    $pingTargets = @()
    if ($gw) { $pingTargets += , @('Gateway', $gw) }
    $pingTargets += , @('Internet 8.8.8.8', '8.8.8.8')
    foreach ($t in $pingTargets) {
        $times = @()
        $fails = 0
        for ($i = 0; $i -lt 2; $i++) {
            try {
                $r = $ping.Send($t[1], 1500)
                if ($r.Status -eq 'Success') { $times += $r.RoundtripTime } else { $fails++ }
            } catch { $fails++ }
        }
        if ($times.Count -gt 0) {
            $avg = [math]::Round(($times | Measure-Object -Average).Average)
            W ("  {0,-18}: {1} ms avg{2}" -f $t[0], $avg, $(if ($fails) { " ({0} lost)" -f $fails } else { '' }))
            if ($t[0] -eq 'Gateway' -and $avg -gt 100) { Flag ("Gateway latency is {0} ms - local network (Wi-Fi?) problem" -f $avg) }
            if ($fails -gt 0) { Flag ("Packet loss pinging {0}" -f $t[0]) }
        } else {
            W ("  {0,-18}: unreachable" -f $t[0])
            Flag ("{0} is unreachable by ping" -f $t[0])
        }
    }

    # ---------------- DNS resolution ----------------
    Sect 'DNS resolution'
    foreach ($h in $DnsTargets) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($h)
            $sw.Stop()
            $first = ($addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1)
            if (-not $first) { $first = $addrs | Select-Object -First 1 }
            W ("  {0,-28} {1,5} ms  -> {2}" -f $h, $sw.ElapsedMilliseconds, $first)
            if ($sw.ElapsedMilliseconds -gt 2000) { Flag ("DNS resolution of {0} took {1} ms - DNS is slow" -f $h, $sw.ElapsedMilliseconds) }
        } catch {
            $sw.Stop()
            W ("  {0,-28} FAILED to resolve" -f $h)
            Flag ("DNS cannot resolve {0}{1}" -f $h, $(if ($RmmApiHost -and $h -eq $RmmApiHost) { ' - the RMM agent itself will drop offline' } else { '' }))
        }
    }

    # ---------------- TCP 443 reachability ----------------
    Sect 'TCP 443 reachability'
    foreach ($endpointHost in $Tcp443Targets) {
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
        else { W ("  {0,-28} FAIL" -f $endpointHost); Flag ("Cannot reach {0}:443" -f $endpointHost) }
    }

    # ---------------- Captive portal / NCSI ----------------
    Sect 'Internet sanity (NCSI probe)'
    try {
        $resp = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $body = [string]$resp.Content
        if ($body.Trim() -eq 'Microsoft Connect Test') {
            W '  NCSI probe   : OK (genuine internet, no captive portal)'
        } else {
            W ("  NCSI probe   : UNEXPECTED content ('{0}')" -f $body.Substring(0, [math]::Min(60, $body.Length)))
            Flag 'NCSI probe returned unexpected content - captive portal or intercepting proxy in the path'
        }
    } catch {
        W '  NCSI probe   : FAILED'
        Flag 'HTTP probe to msftconnecttest.com failed - no working internet path for HTTP'
    }

    # ---------------- Proxy ----------------
    Sect 'Proxy'
    $winhttp = netsh winhttp show proxy 2>$null
    $direct = ($winhttp -join ' ') -match 'Direct access'
    W ("  WinHTTP (system) : {0}" -f $(if ($direct) { 'direct (no proxy)' } else { 'PROXY CONFIGURED - see below' }))
    if (-not $direct) { $winhttp | ForEach-Object { if ($_.Trim()) { W ("    {0}" -f $_.Trim()) } } }
    # Per-user proxy (find console user's hive; HKCU = SYSTEM's own hive under an RMM agent)
    $sid = $null
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer) {
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) {
            try { $sid = (New-Object Security.Principal.NTAccount($owner.Domain, $owner.User)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
        }
    }
    if ($sid) {
        $inet = Get-ItemProperty ("Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -f $sid) -ErrorAction SilentlyContinue
        if ($inet) {
            $userProxyOn = ($inet.ProxyEnable -eq 1)
            W ("  User proxy       : {0}" -f $(if ($userProxyOn) { "ENABLED -> $($inet.ProxyServer)" } else { 'disabled' }))
            if ($inet.AutoConfigURL) { W ("  User PAC file    : {0}" -f $inet.AutoConfigURL) }
            if ($userProxyOn -and -not $inet.ProxyServer) { Flag 'User proxy is enabled but has no server set - browsing will fail' }
        }
    }

    # ---------------- VPN ----------------
    Sect 'VPN'
    $vpnServiceMap = @{
        'PanGPS'                    = 'Palo Alto GlobalProtect'
        'vpnagent'                  = 'Cisco AnyConnect / Secure Client'
        'csc_vpnagent'              = 'Cisco Secure Client'
        'FA_Scheduler'              = 'FortiClient'
        'PulseSecureService'        = 'Ivanti/Pulse Secure'
        'TracSrvWrapper'            = 'Check Point'
        'WireGuardManager'          = 'WireGuard'
        'OpenVPNService'            = 'OpenVPN'
        'OpenVPNServiceInteractive' = 'OpenVPN'
        'Tailscale'                 = 'Tailscale'
        'ZeroTierOneService'        = 'ZeroTier'
    }
    $foundVpn = $false
    foreach ($svcName in $vpnServiceMap.Keys) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $foundVpn = $true
            W ("  Service {0,-26} {1,-8} ({2})" -f $svc.Name, $svc.Status, $vpnServiceMap[$svcName])
            if ($svc.Status -ne 'Running') { Flag ("VPN service '{0}' ({1}) is {2} - start it or reinstall the client" -f $svc.Name, $vpnServiceMap[$svcName], $svc.Status) }
        }
    }
    $vpnAdapterPattern = 'PANGP|AnyConnect|Cisco Secure|Fortinet|FortiSSL|Juniper|Pulse|WireGuard|OpenVPN|TAP-Windows|Tailscale|ZeroTier|Check Point'
    $vpnAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match $vpnAdapterPattern })
    foreach ($va in $vpnAdapters) {
        $foundVpn = $true
        W ("  Adapter {0,-26} {1,-8} ({2})" -f $va.Name, $va.Status, $va.InterfaceDescription)
        if ($va.Status -eq 'Up') {
            $vip = Get-NetIPAddress -InterfaceIndex $va.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vip) { W ("          tunnel IPv4: {0}" -f $vip.IPAddress) }
        }
    }
    $builtin = @()
    try { $builtin += @(Get-VpnConnection -ErrorAction Stop) } catch { }
    try { $builtin += @(Get-VpnConnection -AllUserConnection -ErrorAction Stop) } catch { }
    foreach ($b in $builtin) {
        $foundVpn = $true
        W ("  Windows VPN profile '{0}': {1}" -f $b.Name, $b.ConnectionStatus)
    }
    if (-not $foundVpn) { W '  No VPN client, adapter, or profile detected.' }

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
