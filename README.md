# RMM Script Library

PowerShell troubleshooting scripts for an RMM's "Run Script" feature - written to answer tickets
**without remoting in**. They run the way RMM agents run things: Windows PowerShell 5.1, as SYSTEM,
non-interactive, one self-contained file per script.

The first wave targets the top ticket drivers: Outlook/Teams, VPN/network, docks, general slowness.

## Inventory

| Script | Ticket type | Run As | Mode |
|---|---|---|---|
| `Get-TriageSnapshot.ps1` | any / "computer is slow" - run first on every ticket | System | read-only |
| `Get-M365Health.ps1` | Outlook / Teams / M365 sign-in | System | read-only |
| `Test-NetworkHealth.ps1` | VPN / Wi-Fi / no-or-slow internet | System | read-only |
| `Get-DockDisplayHealth.ps1` | dock / external displays | System | read-only |
| `Grab-Logs.ps1` | ANY ticket - one-shot support bundle: hardware/OS/uptime, RAM+CPU pressure, GPU+TDRs, disk health, hangs/crashes/WER/BSOD/live-kernel dumps, browsers (versions, extensions, GPU accel, crash dumps, Outlook-web site data, policies), Outlook classic+new, Teams, network incl. TLS-inspection + HTTPS TTFB, security agents, recent installs, WU history, error digest | System | read-only; `-Days 7` `-EventLines 30` `-Full` |
| `Get-AIAppInventory.ps1` | AI-usage / shadow-AI check: AI apps, coding assistants, local LLM runtimes, model files, execution evidence | System | read-only (never reads browser history or documents) |
| `Get-PrintDiag.ps1` | printing broken: proves the RMM can run scripts there, shows WPP policy, spooler, drivers, queues | System | read-only |
| `Reset-TeamsCache.ps1` | Teams blank/stuck/stale | **Current User** | report-only unless `-Fix` |
| `Repair-Network.ps1` | connectivity fix after Test-NetworkHealth | System | report-only unless `-Fix` (`-Deep` = stack reset, reboot) |
| `Invoke-DiskCleanup.ps1` | low disk / slowness | System | report-only unless `-Fix` |
| `Enable-LocationServices.ps1` | location off / auto time zone wrong / Teams emergency location | System | report-only unless `-Fix` |
| `Clean-PrinterList.ps1` | print-management cutover: strip queues to PDF-only first | System | report-only unless `-Fix`; keeps USB/label printers on vendor ports by default |
| `Test-AsSystem.ps1` | dev tool - run a library script as SYSTEM locally; **never upload to the RMM** | n/a | harness |

**Rules for fix scripts:**
- Running any script with **no switches is always safe** - it only reports and prints the
  exact actions `-Fix` would take. When in doubt, run bare first and read the plan.
- Every fix script **guards its context**: pick the wrong Run As in the RMM and it exits
  with instructions instead of half-working (user-profile fixes need *Current User*;
  machine fixes need *System*).
- `Reset-TeamsCache -Fix` closes the user's Teams and they may have to sign back in -
  warn the user first. `Repair-Network -Fix` drops the network for a few seconds.
  `-Deep` requires a reboot afterward.
- `Enable-LocationServices -Fix` will **not** override Intune/GPO policy that forces
  location off - it flags the policy and tells you where to lift it. Per-user toggles
  are only fixed for profiles loaded at run time (i.e. someone is signed in).

## Running it under your RMM or Intune

Nothing here is tied to one product. Any tool that can push a PowerShell script to a Windows endpoint and
run it as SYSTEM works: NinjaOne, Datto RMM, ConnectWise Automate, Kaseya VSA, N-able, Syncro, Atera,
Microsoft Intune and the like. Whatever the tool calls its settings, set them like this:

| Setting | Use |
|---|---|
| Script type | PowerShell (Windows PowerShell 5.1) |
| Run as | **System** / local system for everything except `Reset-TeamsCache.ps1`, which needs the tool's *logged-on user* option |
| 32- or 64-bit | Either. Every script relaunches itself in 64-bit PowerShell if the agent starts it in 32-bit |
| Timeout | 5 min default; 10 for Get-M365Health and Grab-Logs; 20 for Get-AIAppInventory |
| Parameters | Pass switches such as `-Fix` or `-Days 7` in the tool's arguments/parameters field |
| Result | Read the console output the tool captures. Exit 1 is "needs attention", not a crash |

### Microsoft Intune: platform scripts

*Devices > Scripts and remediations > Platform scripts.* Set **Run this script using the logged on
credentials** to *No* (SYSTEM), **Enforce script signature check** to *No* unless you sign the scripts, and
leave **Run script in 64-bit PowerShell host** at either value. Platform scripts accept no parameters, run
once per device (with three retries on failure) and time out after 30 minutes. The admin center shows only
success or failure, so read the result from the log copy on the device in `C:\ProgramData\RMMScripts\Logs\`.
All scripts are ASCII and well under the 200 KB upload limit.

### Microsoft Intune: Remediations

The exit codes line up with Remediations: a detection script that exits `1` means "issue found", which is
what triggers the remediation script. Any read-only script (`Get-*`, `Test-*`) works as a detection-only
package, which gives you a fleet-wide report of which devices need attention on a schedule.
`Invoke-DiskCleanup`, `Repair-Network`, `Enable-LocationServices` and `Reset-TeamsCache` also work as
detect-and-fix pairs: upload the script as-is for detection (without `-Fix` it reports and exits 1 when there
is something to fix) and a copy with `[switch]$Fix` changed to `[switch]$Fix = $true` for remediation, since
packages cannot pass arguments (for `Reset-TeamsCache`, set **Run this script using the logged-on
credentials** to *Yes*; the others run as SYSTEM). `Clean-PrinterList` is a one-time cutover tool and exits 0 in report mode,
so run it as a platform script instead. Intune keeps at most 2,048 characters of output per run, so the full
report is again in the device log. Remediations need Windows Enterprise E3/E5 (or Education A3/A5) licensing.

## Reading the output

Skim from the bottom: every script ends with

```
ISSUES FOUND:
  ! <plain-English finding with the suggested next step>
RESULT: NEEDS-ATTENTION (n issue(s))     <- or RESULT: OK
```

Exit codes: `0` OK - `1` needs attention - `2` script error. Most RMMs show exit 1 as "Failed";
that is expected and means "read the findings".
For `Get-AIAppInventory`, exit 1 means "AI indicators found, review" - the script judges nothing.
It also writes a JSON twin next to the log for machine parsing. A copy of every run
is kept on the endpoint at `C:\ProgramData\RMMScripts\Logs\`.

## Conventions (all library scripts)

- Target **Windows PowerShell 5.1**, SYSTEM, `-NonInteractive` - what RMM agents provide.
  No `Read-Host`, no UAC prompts, no PS7-only syntax, ASCII-only output.
- 32->64-bit `sysnative` relaunch shim at the top.
- Self-contained single file (RMMs upload one file; no dot-sourcing).
- User-profile data is read by locating the logged-on user (explorer.exe owner -> SID ->
  `HKEY_USERS\<SID>` + profile path), because HKCU under an RMM agent is SYSTEM's own hive.
- Diagnose first: the first-wave scripts are read-only. Fix scripts default to
  report-only with an explicit `-Fix` switch.

## Test pipeline (do not skip stages)

1. **Local, as SYSTEM** - from an elevated prompt:
   `.\Test-AsSystem.ps1 -ScriptPath .\Get-TriageSnapshot.ps1`
   Catches prompt-hangs and SYSTEM/HKCU assumptions before the RMM is involved.
2. **RMM dev run** - upload as `DEV - <name>`, run against a test endpoint only.
   Catches RMM-side quirks: output truncation, max-run-time, script variables.
   Suggested settings: type *PowerShell*, run as *System*, max run time *5 min*
   (10 for Get-M365Health - cache sizing can be slow on stuffed profiles; 10 for Grab-Logs;
   20 for Get-AIAppInventory - the drive listing is the slow part).
3. **Promote** - clone to the production name and bump the version in the header changelog.

Hardware caveat: validate dock/battery scripts on each laptop family in your fleet before promoting.

## Planned

- `Repair-Office.ps1` - OfficeC2RClient quick repair (force-closes Office apps; needs
  careful gating + user warning)
- `Repair-WindowsUpdate.ps1` - full component reset (SoftwareDistribution/catroot2) + rescan
- `Repair-PrintSpooler.ps1` - purge queue/restart
- ITSM API push: attach script output to the ticket automatically

## License

MIT - see [LICENSE](LICENSE).
