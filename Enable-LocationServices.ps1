<#
================================================================================
  RMM Script Library - Enable-LocationServices
================================================================================
  PURPOSE : Turn Windows location services ON for tickets like "auto time zone
            is wrong", "Teams emergency location missing", "app cannot find my
            location". Covers the whole stack: device-wide toggle (HKLM),
            per-user + desktop-app toggles (loaded profiles), and the
            Geolocation service (lfsvc). Detects GPO/Intune policy that forces
            location OFF and flags it instead of fighting it.

  RMM SETTINGS:
    - Script type : PowerShell
    - Run as      : System (the usual RMM default)
    - Max run time: 5 minutes

  MODES   : (no switch)  REPORT-ONLY - current state + what -Fix would do.
            -Fix         set device-wide toggle to Allow, flip per-user
                         toggles that are explicitly Deny, re-enable lfsvc
                         if disabled, then verify.

  NOTE    : Will NOT override GPO/Intune policy that forces location off -
            that must be lifted at the policy source (flagged in output).
            Per-user toggles are only touched for profiles loaded at run
            time; a profile that is not loaded keeps Windows defaults
            (Allow) unless that user chose Deny - re-run while the user is
            signed in to be certain.

  EXIT CODES:  0 = OK   1 = needs attention   2 = script/context error

  VERSION : 0.1-DEV (2026-07-21)
================================================================================
#>
param([switch]$Fix)

# ---- If launched as 32-bit PowerShell on 64-bit Windows, relaunch 64-bit -----
if ($env:PROCESSOR_ARCHITEW6432) {
    $sysnative = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $sysnative) {
        $extra = @()
        if ($Fix) { $extra += '-Fix' }
        & $sysnative -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath @extra
        exit $LASTEXITCODE
    }
}

$ScriptName    = 'Enable-LocationServices'
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

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

$MasterKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'

# HKCU under an RMM agent is SYSTEM's own hive - enumerate loaded user hives instead.
# Matches domain/local (S-1-5-21-*) and Entra ID (S-1-12-1-*) accounts.
function Get-UserLocationStates {
    $states = New-Object System.Collections.Generic.List[object]
    $hives = Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[0-9-]+$' }
    foreach ($h in $hives) {
        $sid = $h.PSChildName
        $name = $sid
        try {
            $name = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value
        } catch {
            $pp = Get-RegValue -Path ("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\{0}" -f $sid) -Name 'ProfileImagePath'
            if ($pp) { $name = ("{0} ({1})" -f (Split-Path $pp -Leaf), $sid) }
        }
        $base = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
        if (-not (Test-Path "Registry::HKEY_USERS\$sid\Software")) {
            $states.Add([PSCustomObject]@{ Sid = $sid; Name = $name; Base = $base
                UserToggle = '(no access - run as System)'; DesktopToggle = '(no access - run as System)' }) | Out-Null
            continue
        }
        $userVal = Get-RegValue -Path $base -Name 'Value'
        $deskVal = Get-RegValue -Path ("{0}\NonPackaged" -f $base) -Name 'Value'
        if ($null -eq $userVal) { $userVal = '(not set = Allow)' }
        if ($null -eq $deskVal) { $deskVal = '(not set = Allow)' }
        $states.Add([PSCustomObject]@{ Sid = $sid; Name = $name; Base = $base
            UserToggle = $userVal; DesktopToggle = $deskVal }) | Out-Null
    }
    return $states
}

try {
    W ('=' * 64)
    W (" {0}  v{1}   mode: {2}" -f $ScriptName, $ScriptVersion, $(if ($Fix) { 'FIX' } else { 'REPORT-ONLY (run with -Fix to apply)' }))
    W ('=' * 64)
    $ident = [Security.Principal.WindowsIdentity]::GetCurrent()
    W (" Computer   : {0}" -f $env:COMPUTERNAME)
    W (" Running as : {0}" -f $ident.Name)
    W (" Time       : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    # ---- Context guard: fixes write HKLM + service config -> need SYSTEM ----
    $isAdmin = ([Security.Principal.WindowsPrincipal]$ident).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Fix -and -not $isAdmin) {
        W ''
        W 'WRONG RUN-AS CONTEXT.'
        W 'Enabling location services writes HKLM and service config, which'
        W 'needs System rights. In the RMM, re-run with Run As: System (default).'
        W ''
        W 'RESULT: SCRIPT-ERROR (wrong context - nothing was changed)'
        Save-Log
        exit 2
    }

    # ---------------- Policy check (GPO / Intune) ----------------
    Sect 'Policy check (GPO / Intune)'
    $polBlocks = New-Object System.Collections.Generic.List[string]

    $gpoKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
    $dl   = Get-RegValue -Path $gpoKey -Name 'DisableLocation'
    $dwlp = Get-RegValue -Path $gpoKey -Name 'DisableWindowsLocationProvider'
    if ($dl -eq 1)   { W '  GPO "Turn off location" is SET (DisableLocation = 1)';            $polBlocks.Add('GPO LocationAndSensors\DisableLocation = 1') | Out-Null }
    if ($dwlp -eq 1) { W '  GPO "Turn off Windows Location Provider" is SET';                 $polBlocks.Add('GPO LocationAndSensors\DisableWindowsLocationProvider = 1') | Out-Null }

    $mdmLoc  = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System'  -Name 'AllowLocation'
    $mdmApps = Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Privacy' -Name 'LetAppsAccessLocation'
    if ($mdmLoc -eq 0)  { W '  Intune/MDM System/AllowLocation = 0 (location FORCED OFF)';    $polBlocks.Add('MDM System/AllowLocation = 0') | Out-Null }
    if ($mdmLoc -eq 2)  { W '  Intune/MDM System/AllowLocation = 2 (location forced ON)' }
    if ($mdmApps -eq 2) { W '  Intune/MDM Privacy/LetAppsAccessLocation = 2 (app access FORCED DENY)'; $polBlocks.Add('MDM Privacy/LetAppsAccessLocation = 2') | Out-Null }
    if ($mdmApps -eq 1) { W '  Intune/MDM Privacy/LetAppsAccessLocation = 1 (app access forced allow)' }

    $policyBlocked = ($polBlocks.Count -gt 0)
    if (-not $policyBlocked -and $mdmLoc -ne 2 -and $mdmApps -ne 1) {
        W '  No location policy found - setting is user/admin controllable.'
    }
    foreach ($p in $polBlocks) {
        Flag ("Location is forced OFF by policy [{0}] - lift it in Intune/GPO; -Fix cannot and will not override it" -f $p)
    }

    # ---------------- Device-wide toggle ----------------
    Sect 'Device-wide location toggle (all users)'
    $master = Get-RegValue -Path $MasterKey -Name 'Value'
    if ($null -eq $master) { $masterShow = '(missing)' } else { $masterShow = $master }
    W ("  HKLM ConsentStore\location Value : {0}" -f $masterShow)
    $needMaster = ($master -ne 'Allow')

    # ---------------- Geolocation service ----------------
    Sect 'Geolocation service (lfsvc)'
    $svc = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    $needSvc = $false
    if (-not $svc) {
        W '  lfsvc NOT FOUND on this machine.'
        Flag 'Geolocation service (lfsvc) is missing from this Windows image - needs a hands-on look'
    } else {
        W ("  Status : {0}   StartType : {1}" -f $svc.Status, $svc.StartType)
        if ($svc.StartType -eq 'Disabled') {
            $needSvc = $true
        } elseif ($svc.Status -ne 'Running') {
            W '  (Stopped with Manual start is normal - lfsvc is trigger-started on demand.)'
        }
    }

    # ---------------- Per-user toggles ----------------
    Sect 'Per-user toggles (loaded profiles)'
    $users = @(Get-UserLocationStates)
    if ($users.Count -eq 0) {
        W '  No user hives loaded (no one is signed in).'
    }
    foreach ($u in $users) {
        W ("  {0}" -f $u.Name)
        W ("    apps may use location    : {0}" -f $u.UserToggle)
        W ("    desktop apps may use it  : {0}" -f $u.DesktopToggle)
    }
    $denyUsers = @($users | Where-Object { $_.UserToggle -eq 'Deny' -or $_.DesktopToggle -eq 'Deny' })

    # ---------------- Report-only stops here ----------------
    if (-not $Fix) {
        Sect 'Planned actions (re-run with -Fix to apply)'
        $n = 0
        if ($needMaster) {
            $n++; W ("  {0}. Set device-wide location toggle to Allow" -f $n)
            Flag 'Location is OFF at the device level - re-run with -Fix to enable'
        }
        if ($needSvc) {
            $n++; W ("  {0}. Re-enable Geolocation service (Disabled -> Manual) and start it" -f $n)
            Flag 'Geolocation service (lfsvc) is DISABLED - re-run with -Fix to restore it'
        }
        foreach ($u in $denyUsers) {
            $n++; W ("  {0}. Set location toggles for '{1}' to Allow" -f $n, $u.Name)
            Flag ("User '{0}' has location set to Deny - re-run with -Fix to allow" -f $u.Name)
        }
        if ($n -eq 0) {
            W '  Nothing to do - location services are already enabled.'
        }
        Finish
    }

    # ---------------- Fix ----------------
    Sect 'Applying fixes'
    if ($policyBlocked) {
        W '  NOTE: a policy above forces location off. Registry/service fixes'
        W '  below are applied anyway but will NOT take effect until the'
        W '  policy is lifted at the source (Intune/GPO).'
    }

    if ($needMaster) {
        W '  Setting device-wide location toggle to Allow...'
        if (-not (Test-Path $MasterKey)) { New-Item -Path $MasterKey -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $MasterKey -Name 'Value' -Value 'Allow' -ErrorAction Stop
        W '    done.'
    } else {
        W '  Device-wide toggle already Allow - nothing to change.'
    }

    if ($svc) {
        if ($needSvc) {
            W '  Re-enabling Geolocation service (Disabled -> Manual)...'
            Set-Service -Name 'lfsvc' -StartupType Manual -ErrorAction SilentlyContinue
            W '    done.'
        }
        $svcNow = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
        if ($svcNow -and $svcNow.Status -ne 'Running' -and $svcNow.StartType -ne 'Disabled') {
            W '  Starting Geolocation service...'
            Start-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
        }
    }

    foreach ($u in $denyUsers) {
        W ("  Fixing toggles for '{0}'..." -f $u.Name)
        if ($u.UserToggle -eq 'Deny') {
            Set-ItemProperty -Path $u.Base -Name 'Value' -Value 'Allow' -ErrorAction SilentlyContinue
        }
        if ($u.DesktopToggle -eq 'Deny') {
            $np = ("{0}\NonPackaged" -f $u.Base)
            if (-not (Test-Path $np)) { New-Item -Path $np -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $np -Name 'Value' -Value 'Allow' -ErrorAction SilentlyContinue
        }
        W '    done.'
    }
    if ($denyUsers.Count -eq 0) { W '  No per-user toggle was set to Deny - nothing to change.' }

    # ---------------- Verify ----------------
    Sect 'Verification'
    $masterAfter = Get-RegValue -Path $MasterKey -Name 'Value'
    W ("  Device-wide toggle : {0}" -f $masterAfter)
    if ($masterAfter -ne 'Allow') { Flag 'Device-wide toggle is still not Allow after fix - investigate (policy or ACL?)' }

    $svcAfter = Get-Service -Name 'lfsvc' -ErrorAction SilentlyContinue
    if ($svcAfter) {
        W ("  lfsvc              : {0} / {1}" -f $svcAfter.Status, $svcAfter.StartType)
        if ($svcAfter.StartType -eq 'Disabled') { Flag 'Geolocation service is still Disabled after fix' }
    }

    foreach ($u in $denyUsers) {
        $uv = Get-RegValue -Path $u.Base -Name 'Value'
        $dv = Get-RegValue -Path ("{0}\NonPackaged" -f $u.Base) -Name 'Value'
        W ("  {0} : apps={1}  desktop={2}" -f $u.Name, $uv, $dv)
        if ($uv -eq 'Deny' -or $dv -eq 'Deny') { Flag ("Toggles for '{0}' are still Deny after fix" -f $u.Name) }
    }

    if ($policyBlocked) {
        W '  Reminder: policy still forces location off - fixes take effect'
        W '  only after the Intune/GPO policy is lifted.'
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
