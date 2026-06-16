# Troubleshooting

Problems are grouped by where you'll notice them. Each entry: symptom, cause, fix.

When in doubt, check the log first:

```powershell
notepad $env:TEMP\claudecodewsb-map.log
```

Every run of the mapping script (login task, Remount shortcut, manual run) appends here with timestamps.

---

## Drive problems

### My mapped drive shows as disconnected (red X in Explorer)

**Cause:** the WSL VM has terminated. This happens after:
- `wsl --shutdown` (run manually or by another tool)
- A Windows update that restarts WSL components
- Deep sleep / hibernation on some hardware
- The keepalive process being killed

When the VM restarts it gets a **different IP**, so the old mapping points at a dead address.

**Fix:** Start Menu → ClaudeCodeWSB → **Remount ClaudeCodeWSB Drive**. Takes a few seconds: it restarts the keepalive, discovers the new IP, and remaps.

If you prefer the command line:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Scripts\claudecodewsb-map-drive.ps1"
```

### The drive doesn't appear after login

The scheduled task may have fired before WSL was ready, or failed.

1. Check the log: `notepad $env:TEMP\claudecodewsb-map.log` — the last entries show which step failed.
2. Check the task result:
   ```powershell
   Get-ScheduledTask -TaskName "ClaudeCodeWSB Auto-Mount" | Get-ScheduledTaskInfo
   ```
   `LastTaskResult` of `0` means success.
3. If the failure is a timeout waiting for WSL/SMB, increase the login delay by re-running the installer:
   ```powershell
   .\install-windows.ps1 -LoginDelaySeconds 60
   ```

### `System error 67` — "The network name cannot be found"

The SMB server is reachable but the **share name doesn't exist**. Almost always: the share name used by the Windows side doesn't match what the WSL-side installer created.

Check what Samba is actually serving (inside WSL):

```bash
smbclient -L localhost -U <your-user>
```

If the share has a different name, re-run the Windows installer with the right one:

```powershell
.\install-windows.ps1 -ShareName "<actual-name>"
```

### `System error 53` — "The network path was not found"

Windows can't reach the WSL IP at all. Inside WSL, verify Samba is up:

```bash
sudo service smbd status
sudo ss -tlnp | grep 445
```

If smbd isn't running: `sudo service smbd restart`, then check `/var/log/samba/log.smbd` for errors. If smbd is running, verify the IP from Windows:

```powershell
wsl -d <distro> -- hostname -I
Test-NetConnection -ComputerName <that-ip> -Port 445
```

### A drive letter I want is "in use" but I don't see it in Explorer

Drive mappings are per-session and per-elevation. A mapping created in an **admin** PowerShell is not visible to normal Explorer, and vice versa. Check both contexts with `net use`. Stale mappings: `net use X: /delete /yes`.

---

## Unity / Unreal problems

### Errors / asset-database corruption when CREATING a new Unity project on the mapped drive

If you create a brand-new Unity project directly on the mapped drive (Z:), you may
see a flood of errors during the initial import — compiler errors about missing
types (CS0246 / CS0234 for InputSystem, TestRunner, etc.), plus the underlying
cause:

```
Import Error Code:(5)
Message: Build asset version error: projectsettings/...asset does not exit in SourceAssetDB
Has ADB guid but no valid Hash for asset '...'
```

**Cause.** Creating a project is the most write-intensive thing Unity does — it
imports thousands of package files and builds its asset database in a rapid,
concurrent burst. SMB caches and may reorder or delay writes, so Unity records an
asset's hash and then reads back data that hasn't been consistently flushed,
corrupting the asset database as it's built. The "missing type" compiler errors are
downstream symptoms of that corruption, not the real problem.

This affects project **creation/import** only. Opening and working on an
already-imported project on the share is reliable (that's mostly stable reads plus
incremental writes).

**Fix — create locally, then move to the share:**

1. Create the new Unity project on a **local Windows path** (e.g. `C:\dev\MyProject`).
2. Open it once and let Unity finish importing and build its `Library/` folder.
   Confirm the project is error-free locally.
3. Close Unity.
4. Move the entire project folder — **including `Library/`** — onto the share
   (or into `~/dev` on the WSL side, which is the same location).
5. Reopen from the mapped drive. Because the asset database is already built and
   valid, Unity just loads it.

Bring `Library/` along with the move. If you copy everything *except* `Library/`,
Unity rebuilds it on first open from the share — which re-triggers the same
write-heavy import that failed in the first place.

### Unity: "Fatal Error! The project is on case sensitive file system"

Samba's case-insensitivity emulation isn't active. Inside WSL:

```bash
testparm -s 2>/dev/null | grep -i "case sensitive"
```

Must show `case sensitive = No` for the share. If not, the share config was modified or regenerated without the option — re-run the WSL installer, or add `case sensitive = no` to the share section in `/etc/samba/smb.conf` and `sudo service smbd restart`. **Reopen Unity afterwards** (it caches the filesystem probe).

### Burst compiler error: "Unable to load ... DLL, error code 5" / vswhere.exe "Access is denied"

Windows is refusing to execute binaries from the share. Inside WSL:

```bash
testparm -s 2>/dev/null | grep -i "acl allow execute"
```

Must show `acl allow execute always = Yes`. If missing, add it to the share section, restart smbd, and restart Unity.

### Unity opens the project but external file changes aren't detected

File-change notifications over SMB can lag. Workarounds: give Unity focus (it rescans on focus), or use Assets → Refresh (Ctrl+R). If it's persistently broken, report an issue with your Unity version.

---

## WSL-side problems

### smbd crashes at start: "Address already in use" / SIGABRT panic

Something else owns port 445 from the distro's point of view. The most common cause: **WSL mirrored networking mode**, where the distro shares the Windows network stack — and Windows itself owns port 445.

Check `C:\Users\<you>\.wslconfig` for `networkingMode=mirrored`. This project requires **NAT mode** (the default). Remove the mirrored setting, run `wsl --shutdown`, reopen, and `sudo service smbd restart`.

### `error: chmod ... Operation not permitted` when cloning the repo

You ran `git clone` from inside WSL with the working directory on a Windows drive (`/mnt/c/...`, `/mnt/d/...`). NTFS doesn't support Linux file modes, so git fails to set permissions on its own lock files.

Clone into your WSL home directory instead:

```bash
cd ~
git clone https://github.com/<you>/ClaudeCodeWSB.git
```

The repo lives on ext4 (where git works correctly), and the installer's whole point is to make those files accessible from Windows via the mapped drive — so you don't need them on a Windows drive to work with them from Unity, Visual Studio, or any other Windows tool.

### `claude: command not found` after install

The PATH entry is added to `~/.bashrc` but your current shell predates it:

```bash
source ~/.bashrc
claude --version
```

### Claude Code hangs / freezes for ~2 minutes repeatedly

Check where your project is. If you're running Claude Code against a **Windows path** (`/mnt/c/...`, `/mnt/d/...`), you're hitting the exact problem this project exists to avoid — the sandbox interacting with the slow WSL↔Windows filesystem bridge. Move the project to the Linux side (`~/dev/...`) and access it from Windows via the mapped drive instead. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full explanation.

If it hangs on a Linux-side path, that's unexpected — please open an issue with the output of:

```bash
pid=$(pgrep -f "^claude$" | head -1)
cat /proc/$pid/status | grep State
cat /proc/$pid/wchan
```

### The installer failed partway — is my system broken?

No. The installer records progress incrementally, so `uninstall.sh` can clean up a partial install (it knows which steps completed). Original configs are backed up in `~/.claudecodewsb-backups/<timestamp>/` before any modification, and re-running `install.sh` after a failure **reuses the original backups** — it will not overwrite them with half-modified files.

---

## Installer / Windows problems

### "File ... is not digitally signed. You cannot run this script"

Your PowerShell execution policy blocks unsigned scripts. Run with the bypass flag (as all documented commands do):

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

If the files were downloaded as a ZIP, Windows may also have marked them with the "downloaded from the internet" flag:

```powershell
Get-ChildItem -Path . -Recurse | Unblock-File
```

### The scheduled task shows "Running" forever

Press **F5** in Task Scheduler. Its display does not auto-refresh; the task almost certainly finished long ago. The authoritative state:

```powershell
Get-ScheduledTask -TaskName "ClaudeCodeWSB Auto-Mount" | Get-ScheduledTaskInfo
```

### What is the hidden `wsl.exe` process running `sleep infinity`?

That's the **keepalive**, and it's intentional. WSL terminates a distro within seconds when no `wsl.exe` session is attached — even if services like Samba are running inside. The mapping script keeps one hidden `wsl.exe -d <distro> -- sleep infinity` process alive to hold the VM open. It uses negligible resources and dies automatically when you log off. To stop it manually:

```powershell
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" |
  Where-Object { $_.CommandLine -match 'sleep\s+infinity' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

(The drive will disconnect shortly after, once WSL shuts the distro down.)

### "Credentials file not found" when the mapping script runs

`%USERPROFILE%\Scripts\claudecodewsb-cred.xml` is missing — deleted, or the install never completed. Re-run `install-windows.ps1`; it will prompt for the Samba password again.

Note: the credentials file is encrypted with your Windows account's DPAPI key. It cannot be copied to another machine or user account — re-create it there instead.

---

## For contributors

### PowerShell parse errors like "The string is missing the terminator"

The `.ps1` files in this repo **must remain pure ASCII and keep their UTF-8 BOM**. Windows PowerShell 5.1 reads BOM-less files as ANSI; a UTF-8 em-dash (`—`) misread as CP-1252 produces a curly quote (`"`) which PowerShell treats as a string delimiter — terminating a string mid-sentence and producing parse errors that point at the *end* of the file, far from the actual cause. Check for accidental non-ASCII:

```bash
grep -P '[^\x00-\x7F]' windows/*.ps1
```

### Bash scripts fail with `\r` errors or "not found"

CRLF line endings from a Windows editor. Fix:

```bash
sed -i 's/\r$//' wsl/*.sh
```
