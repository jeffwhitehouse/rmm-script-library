# Get-PrintDiag.ps1 - run through the RMM on the problem machine.
# Read-only: proves scripts execute there and shows the print environment.

"User          : $(whoami)"
"PS version    : $($PSVersionTable.PSVersion)"
"64-bit PS     : $([Environment]::Is64BitProcess) (64-bit OS: $([Environment]::Is64BitOperatingSystem))"
"Exec policy   : $(Get-ExecutionPolicy)"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
"Elevated      : $isAdmin"

foreach ($wppKey in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP',
                    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\WPP') {
    $wpp = Get-ItemProperty $wppKey -ErrorAction SilentlyContinue
    if ($wpp) {
        "WPP config    : $wppKey"
        $wpp.PSObject.Properties | Where-Object Name -notlike 'PS*' | ForEach-Object { "                $($_.Name) = $($_.Value)" }
    }
}

try {
    Import-Module PrintManagement -ErrorAction Stop
    "PrintMgmt     : module loaded OK"
} catch {
    "PrintMgmt     : FAILED to load - $_"
}

"Spooler       : $((Get-Service Spooler).Status)"
""
"Installed printer drivers:"
Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { "  $($_.Name)" }
""
"Installed printer queues:"
Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { "  $($_.Name) [$($_.PortName)] ($($_.DriverName))" }

exit 0
