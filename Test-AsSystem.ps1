<#
================================================================================
  Test-AsSystem.ps1  -  DEV TOOL, never upload to the RMM
================================================================================
  PURPOSE : Stage-1 test harness. Runs a library script EXACTLY the way an RMM agent
            will: as NT AUTHORITY\SYSTEM, under Windows PowerShell 5.1, with
            -NonInteractive. Running a script from your own elevated prompt is
            NOT a valid RMM test (different PATH, HKCU, per-user devices).

  USAGE   : From an ELEVATED PowerShell prompt:
              .\Test-AsSystem.ps1 -ScriptPath .\Get-TriageSnapshot.ps1
              .\Test-AsSystem.ps1 -ScriptPath .\Get-M365Health.ps1 -TimeoutSec 600
              .\Test-AsSystem.ps1 -ScriptPath .\X.ps1 -Arguments '-CheckOnly'

  HOW     : Registers a one-shot scheduled task as SYSTEM -> cmd wrapper ->
            powershell.exe 5.1 -NonInteractive -> captures output + exit code
            -> prints both -> removes the task.

  VERSION : 0.2-DEV (2026-07-22)  fix: exit.code came back empty because
            'echo %ERRORLEVEL%>' expands to 'echo 0>' = handle redirect in
            cmd; redirection now leads the line, and the read retries.
================================================================================
#>
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string]$Arguments = '',
    [int]$TimeoutSec = 300,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$TaskName = 'RMM-SystemSimTest'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'This harness must run from an ELEVATED prompt (it registers a scheduled task as SYSTEM).'
    Write-Warning 'Open Windows Terminal / PowerShell as administrator and re-run.'
    exit 1
}

$target = (Resolve-Path $ScriptPath).Path
$workDir = 'C:\ProgramData\RMMScripts\RmmSim'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
$outFile  = Join-Path $workDir 'out.log'
$codeFile = Join-Path $workDir 'exit.code'
$runner   = Join-Path $workDir 'runner.cmd'
Remove-Item $outFile, $codeFile -Force -ErrorAction SilentlyContinue

$ps51 = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$cmdLines = @(
    '@echo off',
    ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" {2} > "{3}" 2>&1' -f $ps51, $target, $Arguments, $outFile),
    ('>"{0}" echo %ERRORLEVEL%' -f $codeFile)
)
Set-Content -Path $runner -Value $cmdLines -Encoding ASCII

# Clean up any stale task from a previous run
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "{0}"' -f $runner)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings | Out-Null

Write-Host ("Running '{0}' as SYSTEM (PS 5.1, non-interactive), timeout {1}s ..." -f (Split-Path $target -Leaf), $TimeoutSec)
Start-ScheduledTask -TaskName $TaskName

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $codeFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
}

$timedOut = -not (Test-Path $codeFile)
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '================ OUTPUT (as SYSTEM, PS 5.1) ================' -ForegroundColor Cyan
if (Test-Path $outFile) { Get-Content $outFile | ForEach-Object { Write-Host $_ } } else { Write-Host '(no output captured)' }
Write-Host '============================================================' -ForegroundColor Cyan
if ($timedOut) {
    Write-Warning ("Timed out after {0}s - task killed/abandoned. Script may hang under the RMM too (prompt? long operation?)." -f $TimeoutSec)
    exit 99
}
$code = $null
foreach ($try in 1..5) {
    $code = Get-Content $codeFile -Raw -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($code)) { break }
    Start-Sleep -Milliseconds 200
}
if ([string]::IsNullOrWhiteSpace($code)) {
    Write-Warning 'exit.code was empty/unreadable - reporting script-error (2). Check the output above.'
    $code = '2'
}
$code = $code.Trim()
Write-Host ("EXIT CODE: {0}   (0=OK  1=needs-attention  2=script-error)" -f $code)
if (-not $Keep) { Remove-Item $runner -Force -ErrorAction SilentlyContinue }
exit [int]$code
