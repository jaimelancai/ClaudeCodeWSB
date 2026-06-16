# ClaudeCodeWSB

**Run Claude Code with full sandboxing on Windows — while keeping your Windows tools (Unity, Unreal Engine, Visual Studio) working on the same files.**

ClaudeCodeWSB configures a WSL2 Ubuntu distro to host your project files on the Linux filesystem (where Claude Code's sandbox works flawlessly) and serves them back to Windows over Samba as a regular mapped drive (where Unity, Unreal, and any other Windows application can use them natively).

```
┌─────────────────────────────┐      ┌──────────────────────────────┐
│   WSL2 (Ubuntu 24.04)       │      │   Windows                    │
│                             │      │                              │
│  Claude Code (sandboxed) ───┼──┐   │   Unity / Unreal / VS  ──────┼──┐
│           │                 │  │   │                              │  │
│           ▼                 │  │   │            ▼                 │  │
│   ~/dev/your-project        │  │   │   Z:\your-project            │  │
│   (ext4, native speed)      │  │   │   (mapped network drive)     │  │
│           ▲                 │  │   │            │                 │  │
│           └── Samba ◄───────┼──┼───┼────────────┘                 │  │
│                             │  │   │                              │  │
└─────────────────────────────┘  │   └──────────────────────────────┘  │
                                 └──── same files, two views ──────────┘
```

## Why this exists

Claude Code supports OS-level sandboxing so that commands it runs are isolated from the rest of your system. On **macOS** this uses Seatbelt and works out of the box. On **Linux** it uses bubblewrap and seccomp and also works out of the box. On **Windows**, there is no native sandboxing — the usual recommendation is to run Claude Code inside WSL2, where the Linux sandboxing primitives are available.

That works — until your project lives on a Windows drive.

When Claude Code runs in WSL2 with its sandbox enabled and the working directory is on a Windows path (`/mnt/c/...`, `/mnt/d/...`), it suffers **repeated freezes of ~100 seconds**. Kernel-level inspection shows the process stuck in uninterruptible disk sleep (`D` state) inside `p9_client_rpc` — the filesystem bridge between WSL and Windows. The sandbox's extra filesystem operations, multiplied by the bridge's per-operation overhead (made worse by antivirus filter drivers on the Windows side), push specific calls past a breaking point.

During the investigation that led to this project, the following approaches were tested and **ruled out**:

- **Antivirus folder exclusions** — no effect; filter drivers stay in the I/O path regardless
- **Docker Desktop bind mounts** — same underlying file-sharing mechanism, identical hangs
- **SMB instead of the 9P bridge (WSL → Windows direction)** — same slowness; the bottleneck is below the protocol layer
- **Opening the project from `\\wsl.localhost\...` in Unity** — Unity refuses: *"The project is on case sensitive file system"*
- **Disabling the sandbox** — works, but gives up the very thing WSL was supposed to provide

The approach that **does** work, and that this project automates:

1. Project files live on the WSL ext4 filesystem — Claude Code runs at native speed with the sandbox fully enabled
2. Samba inside WSL serves the project directory back to Windows
3. Two Samba options make Windows tools happy:
   - `case sensitive = no` — emulates case-insensitive name resolution so Unity accepts the filesystem
   - `acl allow execute always = yes` — lets Windows execute DLLs/EXEs from the share (Unity's Burst compiler, `vswhere.exe`, build tools)
4. Windows maps the share as a normal drive letter — Unity, Unreal, Visual Studio, and Explorer treat it like any local project
5. A keepalive mechanism prevents WSL from terminating the distro when no console is attached (it otherwise shuts down within seconds, taking the share with it)
6. A scheduled task re-establishes everything automatically at every Windows login

## Who this is for

- **Game developers on Windows** using Unity or Unreal Engine who want Claude Code with sandboxing on their projects. Verified working with Unity: project opens from the mapped drive, Burst compiles, scripts open in Visual Studio, full solution rebuilds succeed, and MCP integration with the Unity Editor works (both sides effectively share the same machine, so no firewall gymnastics).
- **Any Windows developer** whose toolchain is Windows-native but who wants Claude Code running in a properly sandboxed Linux environment against the same files.

## Requirements

- Windows 10 (build 19041+) or Windows 11
- WSL2 with an **Ubuntu 24.04** distro (`wsl --install -d Ubuntu-24.04`)
- Sudo access inside the distro
- PowerShell 5.1+ (built into Windows)

## Installation

Two installers, run in order. Both are interactive and idempotent (safe to re-run).

### 1. WSL side (inside your Ubuntu distro)

Clone into your WSL home directory (`~`), **not** a Windows path under `/mnt/`. Cloning to `/mnt/c/...` or `/mnt/d/...` from inside WSL fails with `chmod ... Operation not permitted` because NTFS doesn't support Linux file modes — and this is exactly the kind of cross-filesystem friction ClaudeCodeWSB exists to fix.

```bash
cd ~
git clone https://github.com/<you>/ClaudeCodeWSB.git
cd ClaudeCodeWSB/wsl
chmod +x install.sh
./install.sh
```

This installs Samba, Claude Code, and the sandbox dependencies (bubblewrap, socat); asks where your projects should live (default `~/dev`) and for a Samba password; configures the share with the Unity/Unreal-compatible options; and sets Samba to auto-start with the distro. Existing Samba/WSL configs are backed up before any modification.

### 2. Windows side (PowerShell, no admin required)

```powershell
cd ClaudeCodeWSB\windows
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

This asks which distro to use and which drive letter to map (validating availability); saves your Samba credentials encrypted with DPAPI; installs the keepalive + drive-mapping script; verifies the mapping works; creates a scheduled task that runs at every login; and adds Start Menu shortcuts.

When it finishes, your drive (default `Z:`) is mapped and will come back automatically after every reboot.

## Daily usage

- **Claude Code:** inside WSL, `cd ~/dev/your-project && claude`. Sandbox enabled, full speed.
- **Unity / Unreal / Visual Studio:** open the project from `Z:\your-project` like any local project.
- **Both at once:** edits from either side are immediately visible to the other — they are the same files.
- **If the drive ever shows disconnected** (after `wsl --shutdown`, a Windows update, or deep sleep): Start Menu → ClaudeCodeWSB → **Remount ClaudeCodeWSB Drive**. Takes a few seconds.

## What gets installed where

| Component | Location |
|---|---|
| Samba config | `/etc/samba/smb.conf` (WSL; original backed up) |
| WSL boot config | `/etc/wsl.conf` (WSL; original backed up) |
| Claude Code | `~/.npm-global/` (WSL, user-owned) |
| Mapping + keepalive script | `%USERPROFILE%\Scripts\claudecodewsb-map-drive.ps1` |
| Credentials (DPAPI-encrypted) | `%USERPROFILE%\Scripts\claudecodewsb-cred.xml` |
| Scheduled task | "ClaudeCodeWSB Auto-Mount" (runs at login) |
| Shortcuts | Start Menu → ClaudeCodeWSB |
| Logs | `%TEMP%\claudecodewsb-map.log` |

## Uninstalling

Both sides have uninstallers that restore your previous configuration:

```bash
# WSL side — restores backed-up configs, removes Samba user; your projects are never deleted
./uninstall.sh
```

```powershell
# Windows side — removes mapping, task, shortcuts, keepalive, credentials
powershell -ExecutionPolicy Bypass -File .\uninstall-windows.ps1
```

Both handle partial/failed installs gracefully (best-effort cleanup with per-item checks).

## Known limitations

- **Ubuntu 24.04 only** (the WSL installer is tested against it; other versions prompt for confirmation at your own risk).
- **The WSL IP changes between reboots.** The mapping script rediscovers it automatically at each login, but a manually-typed `\\<ip>\share` path will go stale.
- **The drive depends on the WSL VM being alive.** A hidden keepalive process maintains this during your session, but explicit `wsl --shutdown`, Windows updates, or deep sleep can still terminate the VM — hence the Remount shortcut.
- **The share name must match between the two installers.** If you change it from the default (`dev`) during the WSL install, pass `-ShareName` to the Windows installer.
- **The Samba share may be reachable on your local network** depending on your WSL networking mode. Use a strong password.
- **Create Unity projects on a local disk, then move them to the share.** Unity's
  initial project import writes and hashes thousands of files concurrently, which
  can corrupt the asset database over SMB. Create/import on a local Windows path,
  then move the finished project (including its `Library/` folder) onto the share.
  Working on an already-imported project from the share is reliable; only the
  initial creation needs a local disk. See TROUBLESHOOTING.md for details.


## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). For the full story of *why* this architecture is what it is — the kernel-level diagnosis, the dead ends, and the design decisions — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Support

Bug reports and issues are welcome. This is a side project: I read everything, but I can't promise fixes or response times. Pull requests with fixes are appreciated — especially for environment combinations I can't test.

## License

MIT — see [LICENSE](LICENSE).
