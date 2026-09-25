# Clean-PrinterList.ps1
# RMM Script Library - script type: PowerShell, Run As: System, timeout 5+ min.
# Strips the machine's printer list down to PDF queues only (Microsoft Print
# to PDF, Adobe PDF) so a print-management tool can deploy onto a clean slate.
# REPORT-ONLY by default: prints what would be removed. Run with -Fix to act.
# Persistent log: C:\ProgramData\RMMScripts\PrinterCleanup\Clean-PrinterList.log
# NOTE: keep this file pure ASCII. PowerShell 5.1 reads BOM-less scripts as
# ANSI, and characters like em-dashes inside strings break parsing entirely.

param([switch]$Fix)

# Some RMM agents launch scripts in 32-bit PowerShell; relaunch in 64-bit so
# driver/registry operations see the real system.
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
    if ($Fix) { $argList += '-Fix' }
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" @argList
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

# Queues that always survive
$KeepPatterns = @('Microsoft Print to PDF', 'Adobe PDF*')

# When $true (default), only queues on network ports (TCP/IP, IPP, WSD),
# virtual ports (nul:, PORTPROMPT:, FILE:, fax), or \\server\share  # gitleaks:allow
# connections are removed. Anything on an unrecognized local port - USB desk
# printers, label printers on vendor ports like ESDPRT001 - is kept, because
# a print-management tool will not bring those back. Set $false to remove those too.
$KeepDirectAttached = $true

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Fix -and -not $isAdmin) {
    Write-Output 'ERROR: -Fix requires elevation (SYSTEM or admin). No changes made.'
    exit 1
}

if ((Get-Service -Name Spooler).Status -ne 'Running') {
    Write-Output 'ERROR: Print Spooler service is not running - cannot enumerate printers. Fix the spooler first. No changes made.'
    exit 1
}

try {
    $logDir = 'C:\ProgramData\RMMScripts\PrinterCleanup'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Start-Transcript -Path (Join-Path $logDir 'Clean-PrinterList.log') -Append | Out-Null
} catch { }

$mode = if ($Fix) { 'FIX (removing)' } else { 'REPORT-ONLY (no changes; run with -Fix to apply)' }
Write-Output "Printer cleanup mode: $mode"
Write-Output "Run started $(Get-Date -Format s) as $(whoami) (64-bit: $([Environment]::Is64BitProcess), PS $($PSVersionTable.PSVersion))"

if (Get-Service -Name 'PrinterInstallerLauncher' -ErrorAction SilentlyContinue) {
    Write-Output 'NOTE: PrinterLogic client detected. Any printers it already deployed are removed too; they return on its next refresh.'
}

$keepCount     = 0
$removedQueues = 0
$removedConns  = 0
$removedPorts  = 0
$failCount     = 0
$handledShares = @{}

try {
    $allPorts = @(Get-PrinterPort)

    # --- 1. Print queues ---
    foreach ($printer in @(Get-Printer)) {
        if (($KeepPatterns | Where-Object { $printer.Name -like $_ }).Count -gt 0) {
            Write-Output "KEEP   : $($printer.Name) (keep list)"
            $keepCount++
            continue
        }

        $isConnection  = $printer.Type -eq 'Connection'
        $port          = $allPorts | Where-Object Name -eq $printer.PortName
        $isNetworkPort = ($port -and $port.Description -match 'Standard TCP/IP Port|IPP Port|WSD') -or
                         $printer.PortName -match '^(IP_|Port_|IPP-|WSD-)'
        $isVirtualPort = $printer.PortName -match '^(nul:|PORTPROMPT:|FILE:|SHRFAX)'

        if ($KeepDirectAttached -and -not ($isConnection -or $isNetworkPort -or $isVirtualPort)) {
            Write-Output "KEEP   : $($printer.Name) (local port $($printer.PortName) is not network/virtual - left alone)"
            $keepCount++
            continue
        }

        if ($isConnection) { $handledShares[$printer.Name.ToLower()] = $true }

        if ($Fix) {
            try {
                Remove-Printer -Name $printer.Name
                Write-Output "REMOVED: $($printer.Name) [$($printer.PortName)]"
                $removedQueues++
            } catch {
                Write-Output "FAILED : $($printer.Name) - $_"
                $failCount++
            }
        } else {
            Write-Output "REMOVE : $($printer.Name) [$($printer.PortName)] ($($printer.DriverName))"
            $removedQueues++
        }
    }

    # --- 2. Per-user print-server connections (\\server\share) ---  # gitleaks:allow
    # Any loaded hive with a Printers\Connections key is processed; this
    # covers both AD (S-1-5-21-*) and Entra ID (S-1-12-1-*) sign-ins.
    $loadedHives = @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -notlike '*_Classes' })
    foreach ($hive in $loadedHives) {
        $connKey = "Registry::HKEY_USERS\$($hive.PSChildName)\Printers\Connections"
        if (-not (Test-Path $connKey)) { continue }
        foreach ($conn in @(Get-ChildItem $connKey -ErrorAction SilentlyContinue)) {
            $share = $conn.PSChildName -replace ',', '\'
            if ($handledShares.ContainsKey($share.ToLower())) { continue }
            if ($Fix) {
                try {
                    Remove-Item -Path $conn.PSPath -Recurse -Force
                    Write-Output "REMOVED: per-user connection $share [$($hive.PSChildName)]"
                    $removedConns++
                } catch {
                    Write-Output "FAILED : per-user connection $share - $_"
                    $failCount++
                }
            } else {
                Write-Output "REMOVE : per-user connection $share [$($hive.PSChildName)]"
                $removedConns++
            }
        }
    }

    # Profiles that are not logged on have no loaded hive; be honest about it.
    try {
        $profileSids = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' } | ForEach-Object { $_.PSChildName })
        $loadedNames = @($loadedHives | ForEach-Object { $_.PSChildName })
        $skipped = @($profileSids | Where-Object { $_ -notin $loadedNames })
        if ($skipped.Count -gt 0) {
            Write-Output "NOTE   : $($skipped.Count) user profile(s) not logged on were skipped; any per-user print-server connections there remain until cleaned in-session."
        }
    } catch { }

    # --- 3. Network printer ports ---
    if ($Fix) {
        # Spooler restart releases handles on IPP/WSD ports. Every step here
        # is best-effort: orphaned ports are cosmetic and print-management
        # tools create their own, so nothing in this section may kill the run.
        try {
            Restart-Service Spooler -Force
            Start-Sleep -Seconds 5
        } catch {
            Write-Output "WARNING: could not restart spooler ($_) - port cleanup may be incomplete."
        }
        try {
            $portsInUse = @(Get-Printer -ErrorAction Stop | ForEach-Object { $_.PortName })
            foreach ($port in @(Get-PrinterPort)) {
                $removable = ($port.Description -match 'Standard TCP/IP Port|IPP Port|WSD' -or
                              $port.Name -match '^(IP_|Port_|IPP-|WSD-)')
                if (-not $removable -or $port.Name -in $portsInUse) { continue }
                try {
                    Remove-PrinterPort -Name $port.Name
                    Write-Output "REMOVED: port $($port.Name)"
                    $removedPorts++
                } catch {
                    Write-Output "Could not remove port $($port.Name) - $_"
                }
            }
        } catch {
            Write-Output "WARNING: port cleanup skipped ($_). Queues were still removed; leftover ports are cosmetic."
        }
    } else {
        foreach ($port in $allPorts) {
            if ($port.Description -match 'Standard TCP/IP Port|IPP Port|WSD' -or
                $port.Name -match '^(IP_|Port_|IPP-|WSD-)') {
                Write-Output "REMOVE : port $($port.Name) (once orphaned by queue removal)"
                $removedPorts++
            }
        }
    }
} catch {
    Write-Output "UNEXPECTED ERROR: $_"
    $failCount++
}

Write-Output ''
if ($Fix) {
    Write-Output "Summary: removed $removedQueues queue(s), $removedConns per-user connection(s), $removedPorts port(s); kept $keepCount; failures: $failCount."
    try {
        Write-Output 'Final printer list:'
        Get-Printer | ForEach-Object { Write-Output "  $($_.Name) [$($_.PortName)]" }
    } catch {
        Write-Output "Could not read final printer list - $_"
    }
} else {
    Write-Output "Summary: would remove $removedQueues queue(s), $removedConns per-user connection(s), $removedPorts port(s); keeping $keepCount. Run with -Fix to apply."
}

try { Stop-Transcript | Out-Null } catch { }
if ($failCount -gt 0) { exit 1 } else { exit 0 }
