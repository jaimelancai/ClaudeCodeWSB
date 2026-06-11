# ClaudeCodeWSB - Windows-side uninstaller
#
# Removes everything install-windows.ps1 created:
#   - Scheduled task
#   - Start Menu shortcuts
#   - Mapping script
#   - Credentials (asks first)
#   - Drive mapping
#   - Hidden keepalive process
#
# Works after a complete install AND after a partial/failed install
# (state file with Status=in_progress, or no state file - best-effort mode).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1 -Force
#
# Run as your normal user. Admin not required.

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Continue"  # Continue on errors so cleanup completes

# Match install-windows.ps1 constants
$ScriptsDir   = "$env:USERPROFILE\Scripts"
$ScriptPath   = Join-Path $ScriptsDir "claudecodewsb-map-drive.ps1"
$CredPath     = Join-Path $ScriptsDir "claudecodewsb-cred.xml"
$StatePath    = Join-Path $ScriptsDir "claudecodewsb-install.json"
$TaskName     = "ClaudeCodeWSB Auto-Mount"
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) "ClaudeCodeWSB"

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * $Text.Length) -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host "==> $Text" -ForegroundColor Blue }
function Write-Ok([string]$Text)   { Write-Host "[ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[!]  $Text" -ForegroundColor Yellow }

function Confirm-Yes([string]$Question, [string]$Default = "N") {
    if ($Force) { return $true }
    $promptHint = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Question $promptHint"
    if (-not $answer) { $answer = $Default }
    return ($answer -eq "y" -or $answer -eq "Y")
}

function Read-State {
    if (Test-Path $StatePath) {
        try {
            return (Get-Content $StatePath -Raw | ConvertFrom-Json)
        } catch {
            Write-Warn "Could not parse install state at $StatePath. Using defaults."
        }
    }
    return $null
}

function Stop-DriveMapping([string]$DriveLetter) {
    Write-Header "Removing drive mapping"
    $null = & net.exe use "${DriveLetter}:" 2>$null
    if ($LASTEXITCODE -eq 0) {
        & net.exe use "${DriveLetter}:" /delete /yes 2>&1 | Out-Null
        Write-Ok "Drive ${DriveLetter}: unmapped"
    } else {
        Write-Info "No ${DriveLetter}: mapping found"
    }
}

function Stop-Keepalive([string]$DistroName) {
    Write-Header "Stopping keepalive process"
    $procs = Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'sleep\s+infinity' -and
            ([string]::IsNullOrEmpty($DistroName) -or $_.CommandLine -match [regex]::Escape($DistroName))
        }

    if ($procs) {
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Ok "Stopped keepalive PID $($p.ProcessId)"
            } catch {
                Write-Warn "Could not stop PID $($p.ProcessId): $_"
            }
        }
    } else {
        Write-Info "No keepalive process found"
    }
}

function Remove-Task {
    Write-Header "Removing scheduled task"
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "Task '$TaskName' removed"
    } else {
        Write-Info "No scheduled task '$TaskName' found"
    }
}

function Remove-Shortcuts {
    Write-Header "Removing Start Menu shortcuts"
    if (Test-Path $StartMenuDir) {
        Remove-Item -Path $StartMenuDir -Recurse -Force
        Write-Ok "Removed: $StartMenuDir"
    } else {
        Write-Info "No shortcut directory found"
    }
}

function Remove-Script {
    Write-Header "Removing mapping script"
    if (Test-Path $ScriptPath) {
        Remove-Item $ScriptPath -Force
        Write-Ok "Removed: $ScriptPath"
    } else {
        Write-Info "No mapping script found"
    }
}

function Remove-Credentials {
    Write-Header "Credentials"
    if (Test-Path $CredPath) {
        if (Confirm-Yes "Remove saved credentials?" "Y") {
            Remove-Item $CredPath -Force
            Write-Ok "Credentials removed"
        } else {
            Write-Info "Credentials kept at: $CredPath"
        }
    } else {
        Write-Info "No credentials file found"
    }
}

function Remove-State {
    if (Test-Path $StatePath) {
        Remove-Item $StatePath -Force
        Write-Ok "Install state removed"
    }
}

function Remove-LogFile {
    $logPath = Join-Path $env:TEMP "claudecodewsb-map.log"
    if (Test-Path $logPath) {
        if (Confirm-Yes "Remove log file at ${logPath}?" "Y") {
            Remove-Item $logPath -Force -ErrorAction SilentlyContinue
            Remove-Item "$logPath.old" -Force -ErrorAction SilentlyContinue
            Write-Ok "Log removed"
        }
    }
}

function Main {
    Write-Header "ClaudeCodeWSB - Windows uninstaller"

    $state = Read-State
    $distroName = if ($state) { $state.DistroName } else { "Ubuntu-24.04" }
    $driveLetter = if ($state) { $state.DriveLetter } else { "Z" }

    if ($state) {
        Write-Info "Found install state from $($state.InstallDate)"
        if ($state.Status -eq "in_progress") {
            Write-Warn "This was a PARTIAL/FAILED install. Cleanup will remove whatever exists."
        }
    } else {
        Write-Warn "No install state found - using defaults (drive: $driveLetter, distro: $distroName)"
        Write-Warn "Running in best-effort mode; each step checks before acting."
    }

    if (-not (Confirm-Yes "Proceed with uninstall?")) {
        Write-Info "Cancelled."
        return
    }

    Stop-DriveMapping -DriveLetter $driveLetter
    Stop-Keepalive -DistroName $distroName
    Remove-Task
    Remove-Shortcuts
    Remove-Script
    Remove-Credentials
    Remove-State
    Remove-LogFile

    Write-Header "Uninstall complete"
    Write-Host ""
    Write-Host "The Windows-side configuration has been removed."
    Write-Host "The WSL distro itself was NOT modified."
    Write-Host ""
    Write-Host "To also clean up the WSL-side configuration, run uninstall.sh inside the distro."
}

Main
