# Windows-side installer

These scripts configure Windows to:

1. Mount the WSL Samba share at every login (no manual `net use` needed)
2. Keep the WSL distro alive between sessions (it would otherwise auto-shutdown when idle)
3. Provide a "Remount" shortcut for the occasional cases where things disconnect

Run these **after** you've run the WSL-side `install.sh` inside your Ubuntu distro.

## Requirements

- Windows 10 (build 19041+) or Windows 11
- WSL2 installed and your distro configured via the WSL-side installer
- PowerShell 5.0 or later (built into Windows 10/11)

## Install

In PowerShell as your normal user (no admin needed):

```powershell
cd ClaudeCodeWSB\windows
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

You can override the defaults if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 `
    -DistroName "Ubuntu-24.04" `
    -DriveLetter "Z" `
    -ShareName "dev" `
    -LoginDelaySeconds 30
```

The installer will:

- Verify your WSL distro exists and Samba is running inside
- Prompt for the Samba password (from the WSL-side install)
- Save credentials in `%USERPROFILE%\Scripts\claudecodewsb-cred.xml` (DPAPI-encrypted)
- Copy the mapping/keepalive script to `%USERPROFILE%\Scripts\`
- Test the script once to verify it works
- Create a scheduled task that runs at every login
- Add Start Menu shortcuts under "ClaudeCodeWSB"
- Record what it did in `%USERPROFILE%\Scripts\claudecodewsb-install.json` (for the uninstaller)

If the test mapping succeeds, your drive is already available — open Explorer and `Z:` should be there.

## Why the keepalive?

WSL2 terminates a distro very quickly (within seconds) when no `wsl.exe` process is attached to it, regardless of what services are running inside. Once the distro is gone, your `Z:` drive disconnects.

To prevent this, the mapping script keeps a hidden `wsl.exe` running with `sleep infinity` inside the distro. This holds the WSL VM open as long as your Windows user session exists. When you log off, the process dies and the VM is allowed to shut down normally.

You don't see the hidden process unless you specifically look for it (Task Manager → Details, sorted by command line). Its resource usage is trivial.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1
```

This removes:
- The drive mapping
- The hidden keepalive process
- The scheduled task
- The Start Menu shortcuts
- The mapping script
- (Optionally) the saved credentials
- (Optionally) the log file

Pass `-Force` to skip confirmations.

The WSL distro itself is not modified. To clean up the WSL side too, run `uninstall.sh` inside the distro.

## Files & locations

| File | Location | Purpose |
|---|---|---|
| `install-windows.ps1` | (in this folder) | One-time installer |
| `uninstall-windows.ps1` | (in this folder) | Removes everything |
| `claudecodewsb-map-drive.ps1` | (in this folder, gets copied) | Mapping + keepalive script |
| (installed) `claudecodewsb-map-drive.ps1` | `%USERPROFILE%\Scripts\` | The actually-running script |
| (installed) `claudecodewsb-cred.xml` | `%USERPROFILE%\Scripts\` | DPAPI-encrypted Samba password |
| (installed) `claudecodewsb-install.json` | `%USERPROFILE%\Scripts\` | Install state for uninstaller |
| Log file | `%TEMP%\claudecodewsb-map.log` | Each script run appends here |
| Scheduled task | "ClaudeCodeWSB Auto-Mount" | Runs script at login |
| Start Menu | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClaudeCodeWSB\` | Remount/Open shortcuts |

## Troubleshooting

**`Z:` is disconnected after a Windows update or `wsl --shutdown`**

The WSL VM has terminated. Click "Remount ClaudeCodeWSB Drive" in the Start Menu (or run the script directly). It restarts the keepalive and remaps the drive in a few seconds.

**The install test fails with "Samba (smbd) is not running inside the distro"**

You haven't run the WSL-side `install.sh` yet, or it didn't complete successfully. Go run that first.

**"Credentials file not found" when the script runs**

The credentials file at `%USERPROFILE%\Scripts\claudecodewsb-cred.xml` was deleted or never created. Re-run `install-windows.ps1` and provide credentials again.

**Mapping silently fails at login but works when run manually**

Check `%TEMP%\claudecodewsb-map.log` for the last failure. Often this is timing — WSL needs longer to boot than the default 30-second delay. Re-run install with a longer delay:

```powershell
.\install-windows.ps1 -LoginDelaySeconds 60
```

**ExecutionPolicy errors**

Windows may block running .ps1 files downloaded from the internet. The install command includes `-ExecutionPolicy Bypass` to handle this. If you still see errors, you may need to unblock the files first:

```powershell
Get-ChildItem -Path . -Recurse | Unblock-File
```

**Scheduled task shows "Running" forever**

Press F5 in Task Scheduler to refresh — Task Scheduler doesn't auto-refresh its display and may show stale status. The actual state is whatever `Get-ScheduledTask -TaskName 'ClaudeCodeWSB Auto-Mount' | Get-ScheduledTaskInfo` reports.

See [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) for more.
