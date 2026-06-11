# claudecodewsb-map-drive.ps1
#
# Keeps the WSL distro alive (hidden wsl.exe holding a session open),
# discovers its current IP, and maps the Samba share to a Windows drive letter.
#
# Runs in two contexts:
#   1. Scheduled task at user login (no console output visible)
#   2. Manually via Start Menu shortcut "Remount ClaudeCodeWSB Drive"
#
# Logs to %TEMP%\claudecodewsb-map.log

[CmdletBinding()]
param(
    [string]$DriveLetter = "Z",
    [string]$ShareName = "dev",
    [string]$DistroName = "Ubuntu-24.04",
    [string]$CredentialPath = "$env:USERPROFILE\Scripts\claudecodewsb-cred.xml"
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
$LogPath = Join-Path $env:TEMP "claudecodewsb-map.log"

if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
    Move-Item $LogPath "$LogPath.old" -Force
}

function Log([string]$Message, [string]$Level = "INFO") {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# wsl.exe output can contain interleaved null characters (UTF-16 capture).
# Strip them before parsing.
# NOTE: with ErrorActionPreference=Stop (set above), redirecting a native
# command's stderr converts stderr text into a TERMINATING error in PS 5.1.
# All native calls below relax EAP locally around the invocation.
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

# Fast TCP port test (no ICMP, sub-second timeout when port is closed)
function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        try {
            $client.EndConnect($iar)
            return $true
        } catch {
            return $false
        }
    } finally {
        $client.Close()
    }
}

function Wait-ForSmb {
    param(
        [string]$ComputerName,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -ComputerName $ComputerName -Port 445 -TimeoutMs 500) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# -----------------------------------------------------------------------------
# Keepalive: detect and start hidden wsl.exe holding a session open
# -----------------------------------------------------------------------------
function Get-KeepaliveProcess {
    Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match 'sleep\s+infinity' -and
            $_.CommandLine -match [regex]::Escape($DistroName)
        }
}

function Start-Keepalive {
    Log "Starting WSL keepalive process..."

    $proc = Start-Process -FilePath "wsl.exe" `
        -ArgumentList "-d", $DistroName, "--", "sleep", "infinity" `
        -WindowStyle Hidden `
        -PassThru

    if (-not $proc) {
        throw "Failed to start keepalive wsl.exe process"
    }

    Log "Keepalive started (PID: $($proc.Id))"

    # Give the WSL VM a moment to boot
    Start-Sleep -Milliseconds 1500

    $stillAlive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $stillAlive) {
        throw "Keepalive process exited immediately. Check that distro '$DistroName' exists (wsl -l -v)."
    }
}

function Confirm-Keepalive {
    $existing = Get-KeepaliveProcess
    if ($existing) {
        Log "Keepalive already running (PID: $($existing.ProcessId))"
        return
    }
    Start-Keepalive
}

# -----------------------------------------------------------------------------
# Discover WSL IP
# -----------------------------------------------------------------------------
function Get-WSLIp {
    $maxAttempts = 10
    for ($i = 1; $i -le $maxAttempts; $i++) {
        $output = Get-CleanWslOutput @("-d", $DistroName, "--", "hostname", "-I")
        if ($output) {
            $ip = ($output -split '\s+')[0]
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
                return $ip
            }
        }
        Log "WSL IP not yet available, retrying ($i/$maxAttempts)..." "WARN"
        Start-Sleep -Milliseconds 1000
    }
    throw "Could not determine WSL IP after $maxAttempts attempts"
}

# -----------------------------------------------------------------------------
# Main mapping logic
# -----------------------------------------------------------------------------
function Invoke-Mapping {
    if (-not (Test-Path $CredentialPath)) {
        throw "Credentials file not found at $CredentialPath. Re-run install-windows.ps1."
    }

    Log "Loading credentials..."
    $cred = Import-Clixml -Path $CredentialPath
    $password = $cred.GetNetworkCredential().Password
    Log "Credentials loaded for user: $($cred.UserName)"

    Log "Ensuring WSL keepalive is running..."
    Confirm-Keepalive

    Log "Discovering WSL IP for distro '$DistroName'..."
    $wslIp = Get-WSLIp
    Log "WSL IP: $wslIp"

    Log "Waiting for SMB on ${wslIp}:445..."
    if (-not (Wait-ForSmb -ComputerName $wslIp -TimeoutSeconds 30)) {
        throw "SMB on ${wslIp}:445 not responding after 30s. Check Samba inside the distro (sudo service smbd status)."
    }
    Log "SMB is reachable"

    Log "Removing any stale ${DriveLetter}: mapping..."
    # Direct net.exe invocation - no cmd shell, so special characters in
    # arguments can't break parsing. "Connection not found" stderr is expected
    # when no mapping exists; relax EAP locally so it doesn't become a
    # terminating error (PS 5.1 native-stderr gotcha).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & net.exe use "${DriveLetter}:" /delete /yes 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP

    Log "Mapping ${DriveLetter}: to \\$wslIp\$ShareName..."
    # Direct invocation with argument array. The password is passed as a
    # discrete argument - safe against special characters (&, ^, %, quotes).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & net.exe use "${DriveLetter}:" "\\$wslIp\$ShareName" "/user:$($cred.UserName)" "$password" 2>&1
    $mapExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($mapExit -ne 0) {
        throw "net use failed (exit $mapExit): $output"
    }

    Log "SUCCESS: ${DriveLetter}: mapped to \\$wslIp\$ShareName"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
try {
    Log "=== Script invoked ==="
    Log "Parameters: DriveLetter=$DriveLetter ShareName=$ShareName DistroName=$DistroName"
    Invoke-Mapping
    Log "=== Done ==="
    exit 0
} catch {
    Log "FAILED: $($_.Exception.Message)" "ERROR"
    Log "Stack: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
