#Requires -Version 5.1
<#
.SYNOPSIS
    EdgeGuard - silently uninstalls Microsoft Edge if it is present.

.DESCRIPTION
    Designed to be launched by Task Scheduler at logon (and optionally on a
    repeating interval). It performs a fast existence check first. If Edge is
    not installed it exits immediately with code 0 and changes nothing.

    If Edge IS installed it invokes the bundled RemoveEdge.ps1 with
    -UninstallEdge -NonInteractive, writes a log, and exits.

    Exit codes:
      0 = Edge was not present, or removal succeeded
      2 = Edge was present but is still present after the attempt
      3 = RemoveEdge.ps1 not found
      4 = not running as administrator
      5 = unexpected error

.NOTES
    The uninstaller refuses to run as SYSTEM. The scheduled task MUST be
    configured to run as a regular administrator account with
    "Run with highest privileges".
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$logDir = Join-Path $env:ProgramData 'EdgeGuard'
$logFileName = 'edgeguard.log'

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Message

    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath (Join-Path $logDir $logFileName) -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Fall back to TEMP so a permission problem never kills the watchdog.
        Add-Content -LiteralPath (Join-Path $env:TEMP $logFileName) -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Test-EdgeInstalled {
    # Primary and most reliable signal: the Edge executable itself.
    $exeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )

    foreach ($candidate in $exeCandidates) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $true
        }
    }

    return $false
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ---------------------------------------------------------------- main ----

try {
    Write-Log 'EdgeGuard started.'

    if (-not (Test-EdgeInstalled)) {
        Write-Log 'Edge is not installed. Nothing to do.'
        exit 0
    }

    Write-Log 'Edge detected. Starting silent uninstall.'

    if (-not (Test-IsAdmin)) {
        Write-Log 'ERROR: not running as administrator. The uninstaller requires admin rights.'
        exit 4
    }

    $removeScript = Join-Path $PSScriptRoot 'RemoveEdge.ps1'
    if (-not (Test-Path -LiteralPath $removeScript -PathType Leaf)) {
        Write-Log "ERROR: RemoveEdge.ps1 not found at '$removeScript'."
        exit 3
    }

    $rawOutput = & $removeScript -UninstallEdge -NonInteractive 2>&1 | Out-String
    if (-not [string]::IsNullOrWhiteSpace($rawOutput)) {
        foreach ($line in ($rawOutput -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log ('  ' + $line.Trim())
            }
        }
    }

    # Give the OS a moment to settle the filesystem before re-checking.
    Start-Sleep -Seconds 3

    if (Test-EdgeInstalled) {
        Write-Log 'RESULT: Edge is still present. It will be retried on the next run.'
        exit 2
    }

    Write-Log 'RESULT: Edge was removed successfully.'
    exit 0
} catch {
    Write-Log "ERROR: unexpected failure: $($_.Exception.Message)"
    exit 5
}
