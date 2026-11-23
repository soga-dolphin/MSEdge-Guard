#Requires -Version 5.1
<#
.SYNOPSIS
    Installs / removes / inspects the EdgeGuard scheduled task.

.DESCRIPTION
    -Install            Register the startup watchdog task.
    -WithPeriodicCheck  Also add a repeating trigger every 30 minutes.
    -Uninstall          Remove the scheduled task and the installed files.
    -Status             Show task state and the tail of the log.

.NOTES
    Must be run as a regular administrator (NOT SYSTEM).
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$WithPeriodicCheck,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$taskName = 'EdgeGuard - Remove Edge at startup'
$installDir = Join-Path $env:ProgramData 'EdgeGuard'
$logPath = Join-Path $installDir 'edgeguard.log'
$setupLogPath = Join-Path $env:TEMP 'edgeguard-setup.log'

function Write-SetupLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $setupLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-SetupLog ("=== Setup started: {0} / PSRoot={1} ===" -f $PSCommandPath, $PSScriptRoot)

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Write-Line {
    param([string]$Text = '', [string]$Colour = 'White')
    Write-Host $Text -ForegroundColor $Colour
}

# -- elevation ------------------------------------------------------------

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -eq 'S-1-5-18') {
    Write-Line 'This script cannot run as SYSTEM. Launch it from a normal administrator account.' 'Red'
    if (-not $NonInteractive) { $null = Read-Host 'Press Enter to exit' }
    exit 1
}

if (-not (Test-IsAdmin)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    foreach ($switchName in @('Install', 'Uninstall', 'Status', 'WithPeriodicCheck', 'NonInteractive')) {
        if ($PSBoundParameters.ContainsKey($switchName) -and $PSBoundParameters[$switchName]) {
            $argLine += ' -{0}' -f $switchName
        }
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
    exit 0
}

# -- helpers ---------------------------------------------------------------

function Get-EdgeGuardTask {
    return Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

function Install-EdgeGuard {
    Write-SetupLog 'Install-EdgeGuard: begin'
    Write-Line 'Installing EdgeGuard...' 'Cyan'

    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    $required = @('EdgeGuard.ps1', 'RemoveEdge.ps1', 'ClearUpdateBlocks.ps1', 'LICENSE', 'README-ja.md')
    foreach ($file in $required) {
        $source = Join-Path $PSScriptRoot $file
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $installDir $file) -Force
            Write-Line ("  copied: {0}" -f $file) 'Green'
        } else {
            Write-Line ("  WARNING missing: {0}" -f $source) 'Yellow'
        }
    }

    Write-SetupLog ("Install-EdgeGuard: files copied from {0}" -f $PSScriptRoot)

    $guardScript = Join-Path $installDir 'EdgeGuard.ps1'
    if (-not (Test-Path -LiteralPath $guardScript -PathType Leaf)) {
        throw "EdgeGuard.ps1 is missing from '$installDir'. Cannot register the task."
    }

    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $guardScript
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments

    $userAccount = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $userSid = $currentIdentity.User.Value

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userAccount
    $triggers = @($logonTrigger)

    if ($WithPeriodicCheck) {
        $repeatAt = (Get-Date).AddMinutes(5)
        $triggers += New-ScheduledTaskTrigger -Once -At $repeatAt -RepetitionInterval (New-TimeSpan -Minutes 30)
        Write-Line '  repeating trigger added: every 30 minutes' 'Green'
    }

    $settings = New-ScheduledTaskSettingsSet `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 5)

    $description = 'Silently uninstalls Microsoft Edge at logon if it is installed. Added by EdgeGuard.'

    try {
        $principal = New-ScheduledTaskPrincipal -UserId $userAccount -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $description -Force | Out-Null
    } catch {
        Write-SetupLog ("Install-EdgeGuard: register by account failed: {0}" -f $_.Exception.Message)
        Write-Line ("  Register with account name failed ({0}); retrying with SID." -f $_.Exception.Message) 'Yellow'
        $principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $description -Force | Out-Null
    }

    Write-SetupLog ("Install-EdgeGuard: task registered for {0}" -f $userAccount)
    Write-Line ''
    Write-Line 'Installed.' 'Green'
    Write-Line ("  Task name : {0}" -f $taskName)
    Write-Line ("  Files     : {0}" -f $installDir)
    Write-Line ("  Log       : {0}" -f $logPath)
    Write-Line ''
    Write-Line 'Note: the uninstaller refuses to run as SYSTEM, so the task runs as' 'Yellow'
    Write-Line ("      {0} with highest privileges." -f $userAccount) 'Yellow'
}

function Remove-EdgeGuard {
    Write-SetupLog 'Remove-EdgeGuard: begin'
    Write-Line 'Removing EdgeGuard...' 'Cyan'

    if (Get-EdgeGuardTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -Force -ErrorAction SilentlyContinue
        Write-Line '  scheduled task removed.' 'Green'
    } else {
        Write-Line '  scheduled task was not found.' 'Yellow'
    }

    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Line '  installed files removed.' 'Green'
    }

    Write-Line 'Done. (Microsoft Edge itself is NOT reinstalled by this step.)' 'Green'
}

function Show-EdgeGuardStatus {
    Write-Line 'EdgeGuard status' 'Cyan'
    $task = Get-EdgeGuardTask
    if ($task) {
        $task | Select-Object TaskName, State, TaskPath | Format-List | Out-Host
        Write-Line 'Triggers:' 'White'
        $task.Triggers | Format-List | Out-Host
    } else {
        Write-Line '  Scheduled task is NOT installed.' 'Yellow'
    }

    Write-Line ''
    if (Test-Path -LiteralPath $logPath) {
        Write-Line ("Last 20 log lines ({0}):" -f $logPath) 'White'
        Get-Content -LiteralPath $logPath -Tail 20
    } else {
        Write-Line '  No log file yet.' 'Yellow'
    }
}

# -- dispatch --------------------------------------------------------------

trap {
    Write-SetupLog ("FATAL: {0}" -f $_.Exception.Message)
    break
}

if ($Install) { Install-EdgeGuard }
elseif ($Uninstall) { Remove-EdgeGuard }
elseif ($Status) { Show-EdgeGuardStatus }
else {
    Write-Line 'Specify -Install, -Uninstall or -Status. See Get-Help for details.' 'Yellow'
}

Write-SetupLog 'Setup finished.'

if (-not $NonInteractive) {
    Write-Line ''
    $null = Read-Host 'Press Enter to exit'
}
