# ClaudeCodeWSB - Windows-side installer
#
# Sets up the Windows-side persistence for the ClaudeCodeWSB WSL setup:
#   - Saves Samba credentials securely (DPAPI)
#   - Installs the keepalive + drive-mapping script
#   - Creates a scheduled task that runs it at every login
#   - Creates Start Menu shortcuts for manual remap
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#   powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -DistroName "MyDistro" -DriveLetter "Y" -ShareName "projects"
#
# Run as your normal user. Admin is NOT required.
#
# Safe to re-run: existing task is replaced, existing credentials can be reused.

[CmdletBinding()]
param(
    [string]$DistroName = "Ubuntu-24.04",
    [string]$DriveLetter = "Z",
    [string]$ShareName = "dev",
    [int]$LoginDelaySeconds = 30
)

$ErrorActionPreference = "Stop"

# Capture whether parameters were explicitly provided (must be done at script
# scope - inside a function, $PSBoundParameters refers to that function's params)
$script:DistroNameExplicit = $PSBoundParameters.ContainsKey('DistroName')
$script:DriveLetterExplicit = $PSBoundParameters.ContainsKey('DriveLetter')

# PowerShell 5.1 gotcha: with ErrorActionPreference=Stop, redirecting a native
# command's stderr (2>$null / 2>&1) converts harmless stderr text into a
# TERMINATING error. Run such commands with EAP temporarily relaxed.
function Invoke-NativeQuiet {
    param([string]$FilePath, [string[]]$ArgumentList)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
$ScriptsDir   = "$env:USERPROFILE\Scripts"
$ScriptName   = "claudecodewsb-map-drive.ps1"
$ScriptPath   = Join-Path $ScriptsDir $ScriptName
$CredPath     = Join-Path $ScriptsDir "claudecodewsb-cred.xml"
$StatePath    = Join-Path $ScriptsDir "claudecodewsb-install.json"
$TaskName     = "ClaudeCodeWSB Auto-Mount"
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) "ClaudeCodeWSB"

# Locate the bundled mapping script - support running from the repo layout
# (script alongside this installer) or from a flat copy.
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceScript = $null
foreach ($candidate in @(
    (Join-Path $SourceDir $ScriptName),
    (Join-Path $SourceDir "windows\$ScriptName")
)) {
    if (Test-Path $candidate) { $SourceScript = $candidate; break }
}

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * $Text.Length) -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host "==> $Text" -ForegroundColor Blue }
function Write-Ok([string]$Text)   { Write-Host "[ok] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[!]  $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "[x]  $Text" -ForegroundColor Red }

# wsl.exe output can contain interleaved nulls (UTF-16 capture); strip them.
# Returns a single trimmed string - use only for single-value outputs.
function Get-CleanWslOutput([string[]]$WslArgs) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & wsl.exe @WslArgs 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($null -eq $raw) { return "" }
    return ("$raw" -replace "`0", "").Trim()
}

# Returns the list of installed distros as a proper string array,
# preserving line structure (Get-CleanWslOutput would flatten it).
function Get-WslDistroList {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & wsl.exe -l -q 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($null -eq $raw) { return @() }
    return @($raw | ForEach-Object { ("$_" -replace "`0", "").Trim() } | Where-Object { $_ })
}

# Infrastructure distros that should never be offered for selection
$script:InfraDistros = @("docker-desktop", "docker-desktop-data", "rancher-desktop", "rancher-desktop-data")

function Select-Distro {
    param([string]$RequestedName, [bool]$ExplicitlyRequested)

    $all = Get-WslDistroList
    if ($all.Count -eq 0) {
        throw "No WSL distros found. Install one first: wsl --install -d Ubuntu-24.04"
    }

    # Explicit request: validate strictly
    if ($ExplicitlyRequested) {
        if ($all -contains $RequestedName) { return $RequestedName }
        throw "WSL distro '$RequestedName' not found. Available: $($all -join ', ')"
    }

    $candidates = @($all | Where-Object { $script:InfraDistros -notcontains $_ })
    if ($candidates.Count -eq 0) {
        throw "No usable WSL distros found (only infrastructure distros present: $($all -join ', '))"
    }

    # Single candidate: use it without ceremony
    if ($candidates.Count -eq 1) {
        Write-Ok "Using the only available distro: $($candidates[0])"
        return $candidates[0]
    }

    # Multiple candidates: interactive menu, defaulting to the requested name if present
    Write-Host ""
    Write-Host "Multiple WSL distros found. Which one has the ClaudeCodeWSB WSL-side install?"
    $defaultIndex = 1
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $marker = ""
        if ($candidates[$i] -eq $RequestedName) {
            $defaultIndex = $i + 1
            $marker = " (default)"
        }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $candidates[$i], $marker)
    }
    $choice = Read-Host "Select distro [1-$($candidates.Count)] (Enter for $defaultIndex)"
    if (-not $choice) { $choice = $defaultIndex }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $candidates.Count) {
        throw "Invalid selection: $choice"
    }
    return $candidates[$index - 1]
}

# -----------------------------------------------------------------------------
# Drive letter selection / validation
# -----------------------------------------------------------------------------

# Returns info about a drive letter: 'free', 'network' (existing mapping that
# can be replaced), or 'local' (disk/CD/removable - must not be touched).
function Get-DriveLetterStatus([string]$Letter) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${Letter}:'" -ErrorAction SilentlyContinue
    if (-not $disk) { return 'free' }
    if ($disk.DriveType -eq 4) { return 'network' }
    return 'local'
}

function Get-FreeDriveLetters {
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0,1).ToUpper() })
    # Offer letters from Z downward (conventional for network drives), skip A/B (legacy floppy)
    return @([char[]](90..67) | ForEach-Object { "$_" } | Where-Object { $used -notcontains $_ })
}

function Select-DriveLetter {
    param([string]$RequestedLetter, [bool]$ExplicitlyRequested)

    $RequestedLetter = "$RequestedLetter".Trim().TrimEnd(':').ToUpper()
    if ($RequestedLetter -notmatch '^[C-Z]$') {
        if ($ExplicitlyRequested) { throw "Invalid drive letter '$RequestedLetter'. Use a single letter C-Z." }
        $RequestedLetter = "Z"
    }

    if ($ExplicitlyRequested) {
        $status = Get-DriveLetterStatus $RequestedLetter
        switch ($status) {
            'local'   { throw "Drive ${RequestedLetter}: is a local disk and cannot be used. Pick another letter." }
            'network' { Write-Warn "Drive ${RequestedLetter}: has an existing network mapping - it will be replaced." }
        }
        return $RequestedLetter
    }

    # Interactive: loop until a usable letter is chosen
    $free = Get-FreeDriveLetters
    Write-Host ""
    Write-Host "Which drive letter should the share be mounted as?"
    Write-Host "Available letters: " -NoNewline
    Write-Host ($free -join ' ') -ForegroundColor Green
    $default = if ($free -contains $RequestedLetter) { $RequestedLetter } elseif ($free.Count -gt 0) { $free[0] } else { $RequestedLetter }

    while ($true) {
        $choice = Read-Host "Drive letter (Enter for $default)"
        if (-not $choice) { $choice = $default }
        $choice = "$choice".Trim().TrimEnd(':').ToUpper()

        if ($choice -notmatch '^[C-Z]$') {
            Write-Warn "Enter a single letter between C and Z."
            continue
        }

        $status = Get-DriveLetterStatus $choice
        if ($status -eq 'local') {
            Write-Warn "${choice}: is a local disk - pick a different letter."
            continue
        }
        if ($status -eq 'network') {
            Write-Warn "${choice}: already has a network mapping."
            $replace = Read-Host "Replace the existing ${choice}: mapping? (y/N)"
            if ($replace -ne 'y' -and $replace -ne 'Y') { continue }
        }
        return $choice
    }
}

# -----------------------------------------------------------------------------
# Install state (written EARLY with status=in_progress so the uninstaller can
# clean up after a partial failure; flipped to complete at the end)
# -----------------------------------------------------------------------------
function Save-State([string]$Status) {
    $state = @{
        Status          = $Status
        InstallDate     = (Get-Date).ToString("o")
        DistroName      = $DistroName
        DriveLetter     = $DriveLetter
        ShareName       = $ShareName
        WSLUser         = $script:WSLUser
        ScriptPath      = $ScriptPath
        CredPath        = $CredPath
        TaskName        = $TaskName
        StartMenuDir    = $StartMenuDir
        LoginDelay      = $LoginDelaySeconds
    }
    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
function Test-Prerequisites {
    Write-Header "Checking prerequisites"

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.0 or later required."
    }
    Write-Ok "PowerShell version: $($PSVersionTable.PSVersion)"

    try {
        $null = & wsl.exe --version
    } catch {
        throw "wsl.exe not found. Install WSL2 first: wsl --install"
    }
    Write-Ok "WSL is installed"

    $selected = Select-Distro -RequestedName $DistroName -ExplicitlyRequested $script:DistroNameExplicit
    Set-Variable -Name DistroName -Value $selected -Scope Script
    Write-Ok "Distro selected: $selected"

    $selectedLetter = Select-DriveLetter -RequestedLetter $DriveLetter -ExplicitlyRequested $script:DriveLetterExplicit
    Set-Variable -Name DriveLetter -Value $selectedLetter -Scope Script
    Write-Ok "Drive letter selected: ${selectedLetter}:"

    if (-not $SourceScript) {
        throw "Bundled script '$ScriptName' not found next to this installer. The package may be incomplete."
    }
    Write-Ok "Bundled mapping script found: $SourceScript"
}

# -----------------------------------------------------------------------------
# Verify WSL-side setup is in place
# -----------------------------------------------------------------------------
function Test-WSLSide {
    Write-Header "Verifying WSL-side setup"

    Write-Info "Starting distro and checking Samba..."

    # Boot the distro (fires /etc/wsl.conf [boot] command which starts Samba)
    $null = Get-CleanWslOutput @("-d", $DistroName, "--", "echo", "boot-check")
    Start-Sleep -Seconds 2

    $smbStatus = Get-CleanWslOutput @("-d", $DistroName, "--", "sh", "-c", "pgrep -x smbd > /dev/null && echo running || echo stopped")
    if ($smbStatus -ne "running") {
        throw "Samba (smbd) is not running inside '$DistroName'. Run the WSL-side install.sh first. (status: '$smbStatus')"
    }
    Write-Ok "Samba is running inside the distro"

    $script:WSLUser = Get-CleanWslOutput @("-d", $DistroName, "--", "whoami")
    if (-not $script:WSLUser) {
        throw "Could not determine the distro user."
    }
    Write-Ok "Distro user: $script:WSLUser"

    $ipOutput = Get-CleanWslOutput @("-d", $DistroName, "--", "hostname", "-I")
    $script:WSLIp = ($ipOutput -split '\s+')[0]
    Write-Ok "WSL IP (this session): $script:WSLIp"
}

# -----------------------------------------------------------------------------
# Gather credentials
# -----------------------------------------------------------------------------
function Get-SambaCredentials {
    Write-Header "Samba credentials"

    if (Test-Path $CredPath) {
        Write-Warn "Existing credentials found at: $CredPath"
        $reuse = Read-Host "Use existing credentials? (Y/n)"
        if ($reuse -ne "n" -and $reuse -ne "N") {
            Write-Ok "Using existing credentials"
            return
        }
    }

    Write-Info "Enter the Samba password you set during the WSL-side install"
    $cred = Get-Credential -UserName $script:WSLUser -Message "Samba password for ClaudeCodeWSB"

    if (-not $cred) {
        throw "No credentials entered. Cancelled."
    }

    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
    $cred | Export-Clixml -Path $CredPath
    Write-Ok "Credentials saved (DPAPI-encrypted) to $CredPath"
}

# -----------------------------------------------------------------------------
# Install the mapping/keepalive script
# -----------------------------------------------------------------------------
function Install-Script {
    Write-Header "Installing mapping script"

    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
    Copy-Item -Path $SourceScript -Destination $ScriptPath -Force
    Write-Ok "Mapping script installed to: $ScriptPath"
}

# -----------------------------------------------------------------------------
# Test it once before scheduling
# -----------------------------------------------------------------------------
function Test-MappingScript {
    Write-Header "Testing the mapping script"

    Write-Info "Running script once to verify it works..."

    # Clean slate (stale-mapping delete; "not found" stderr is expected and harmless)
    $null = Invoke-NativeQuiet -FilePath "net.exe" -ArgumentList @("use", "${DriveLetter}:", "/delete", "/yes")

    # IMPORTANT: do NOT use Start-Process -Wait here. In Windows PowerShell 5.1
    # it waits for the entire process tree - and the mapping script spawns the
    # hidden keepalive (wsl.exe running 'sleep infinity'), which never exits.
    # Direct invocation (&) waits only for powershell.exe itself.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
        -DriveLetter $DriveLetter -ShareName $ShareName -DistroName $DistroName
    $testExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($testExit -ne 0) {
        throw "Test mapping failed (exit code $testExit). See log: $env:TEMP\claudecodewsb-map.log"
    }

    if (-not (Test-Path "${DriveLetter}:\")) {
        throw "Mapping reported success but ${DriveLetter}:\ is not accessible."
    }

    Write-Ok "Drive ${DriveLetter}: mapped successfully"
}

# -----------------------------------------------------------------------------
# Scheduled task
# -----------------------------------------------------------------------------
function Install-ScheduledTask {
    Write-Header "Creating scheduled task"

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Info "Removing existing scheduled task..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -DriveLetter $DriveLetter -ShareName $ShareName -DistroName $DistroName"

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trigger.Delay = "PT${LoginDelaySeconds}S"

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "ClaudeCodeWSB: keeps the WSL distro alive and maps $DriveLetter`: to the Samba share at login" | Out-Null

    Write-Ok "Scheduled task '$TaskName' created (runs at login with ${LoginDelaySeconds}s delay)"
}

# -----------------------------------------------------------------------------
# Start Menu shortcuts
# -----------------------------------------------------------------------------
function Install-Shortcuts {
    Write-Header "Creating shortcuts"

    New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null

    $shell = New-Object -ComObject WScript.Shell

    $remountLink = $shell.CreateShortcut((Join-Path $StartMenuDir "Remount ClaudeCodeWSB Drive.lnk"))
    $remountLink.TargetPath = "powershell.exe"
    $remountLink.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -DriveLetter $DriveLetter -ShareName $ShareName -DistroName $DistroName"
    $remountLink.WorkingDirectory = $ScriptsDir
    $remountLink.Description = "Re-establish the $DriveLetter`: drive if it has disconnected"
    $remountLink.Save()
    Write-Ok "Shortcut: Remount ClaudeCodeWSB Drive"

    $openLink = $shell.CreateShortcut((Join-Path $StartMenuDir "Open $DriveLetter`: Drive.lnk"))
    $openLink.TargetPath = "${DriveLetter}:\"
    $openLink.Description = "Open the ClaudeCodeWSB shared drive in Explorer"
    $openLink.Save()
    Write-Ok "Shortcut: Open $DriveLetter`: Drive"

    Write-Ok "Shortcuts available in Start Menu under 'ClaudeCodeWSB'"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
function Show-Summary {
    Write-Header "Setup complete!"
    Write-Host ""
    Write-Host "Drive ${DriveLetter}: is mapped now and will auto-remap at every Windows login." -ForegroundColor Green
    Write-Host ""
    Write-Host "Files installed:" -ForegroundColor Cyan
    Write-Host "  Mapping script:  $ScriptPath"
    Write-Host "  Credentials:     $CredPath (encrypted)"
    Write-Host "  Install state:   $StatePath"
    Write-Host "  Shortcuts:       Start Menu -> ClaudeCodeWSB"
    Write-Host ""
    Write-Host "Useful commands:" -ForegroundColor Cyan
    Write-Host "  Test the task manually:   Task Scheduler -> '$TaskName' -> Run"
    Write-Host "  Re-map the drive:         Start Menu -> ClaudeCodeWSB -> Remount ClaudeCodeWSB Drive"
    Write-Host "  Open the share:           Start Menu -> ClaudeCodeWSB -> Open ${DriveLetter}: Drive"
    Write-Host "  Check the log:            notepad `$env:TEMP\claudecodewsb-map.log"
    Write-Host "  Uninstall:                powershell -ExecutionPolicy Bypass -File uninstall-windows.ps1"
    Write-Host ""
    Write-Host "Note: the WSL distro auto-terminates without an attached session." -ForegroundColor Yellow
    Write-Host "The mapping script keeps a hidden 'wsl.exe' running to prevent that."
    Write-Host "If you ever see ${DriveLetter}: disconnected, click 'Remount ClaudeCodeWSB Drive'."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
function Main {
    Write-Header "ClaudeCodeWSB - Windows installer"
    Write-Host ""
    $distroDisplay = if ($script:DistroNameExplicit) { $DistroName } else { "you will be asked (default: $DistroName)" }
    $letterDisplay = if ($script:DriveLetterExplicit) { "${DriveLetter}:" } else { "you will be asked (default: ${DriveLetter}:)" }
    Write-Host "Configuration:"
    Write-Host "  Distro:        $distroDisplay"
    Write-Host "  Drive letter:  $letterDisplay"
    Write-Host "  Share name:    $ShareName"
    Write-Host "  Login delay:   ${LoginDelaySeconds}s"
    Write-Host ""
    Write-Host "This will:"
    Write-Host "  - Verify your WSL distro is configured correctly"
    Write-Host "  - Save your Samba credentials (encrypted)"
    Write-Host "  - Install the keepalive + mapping script to $ScriptsDir"
    Write-Host "  - Create a scheduled task to run it at every login"
    Write-Host "  - Add Start Menu shortcuts for manual remount"
    Write-Host ""
    $proceed = Read-Host "Continue? (Y/n)"
    if ($proceed -eq "n" -or $proceed -eq "N") {
        Write-Info "Cancelled."
        exit 0
    }

    Test-Prerequisites
    Test-WSLSide

    # Record state EARLY so the uninstaller can clean up a partial install
    Save-State -Status "in_progress"

    Get-SambaCredentials
    Install-Script
    Test-MappingScript
    Install-ScheduledTask
    Install-Shortcuts

    Save-State -Status "complete"
    Show-Summary
}

try {
    Main
} catch {
    Write-Host ""
    Write-Err "Install failed: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "Partial state may exist. To clean up, run: uninstall-windows.ps1"
    Write-Host "Log file (if the mapping script ran): $env:TEMP\claudecodewsb-map.log"
    exit 1
}
