# Architecture

This document explains *why* ClaudeCodeWSB is designed the way it is: the problem it solves, the evidence behind the diagnosis, the alternatives that were tested and ruled out, and the reasoning behind each component. If you only want to use the project, the [README](../README.md) is enough. Read this if you want to understand it, debug it, or extend it.

## The problem

Claude Code supports OS-level sandboxing for the commands it runs. On Linux this is built on bubblewrap, seccomp filters, and namespaces. Windows has no equivalent primitives, so the standard recommendation for sandboxed Claude Code on Windows is to run it inside WSL2.

This works perfectly — as long as the working directory is on the **Linux filesystem**. The moment the project lives on a Windows drive (`/mnt/c/...`, `/mnt/d/...`), Claude Code with the sandbox enabled suffers repeated freezes of roughly 100 seconds, during which the terminal is completely unresponsive.

### Kernel-level diagnosis

Inspecting the hung process from a second WSL terminal:

```
$ cat /proc/<pid>/status | grep State
State:  D (disk sleep)            # uninterruptible — cannot even be killed
$ cat /proc/<pid>/wchan
p9_client_rpc                     # blocked in a 9P filesystem RPC to Windows
```

The 9P protocol is the bridge WSL2 uses to expose Windows drives to Linux. The process is waiting, inside the kernel, for the Windows side to answer a filesystem request — and the answer takes ~100 seconds to arrive.

When the same Claude Code runs against the same project with the **sandbox disabled**, the hangs disappear. The sandbox setup (namespace creation, bind mounts, additional stat calls per executed command) multiplies the number of filesystem operations crossing the bridge, and pushes specific calls past whatever timeout produces the stall. The sandbox is the trigger; the slow bridge is the enabling condition.

### Quantifying the bridge

A metadata-heavy benchmark over a real Unity project (54,609 files), `time find . -type f -exec stat {} \; > /dev/null`:

| Location | wall time | user CPU |
|---|---|---|
| `/mnt/d/` (Windows drive via 9P) | 2m 15s | 44s |
| `~/dev/` (WSL ext4) | 1m 30s | 4s |
| Docker Desktop bind mount of the same Windows folder | 2m 11s | 47s |

Two observations. First, the Windows-drive path burns **11× more user-mode CPU** for identical work — evidence of per-operation processing on the Windows side, consistent with antivirus **filter drivers** intercepting every file operation (`fltmc filters` on the test machine showed Avira's `rtp1`/`rtp2` plus a `BdSentry` Bitdefender driver in the I/O stack). Second, excluding the project folder from the antivirus made **no measurable difference** — folder exclusions skip content *scanning*, but the filter drivers remain in the I/O path and their interception overhead persists.

## Ruled-out alternatives

Each of these was tested, not assumed. Documenting them saves the next person the same week.

**Antivirus exclusions.** No effect on the benchmark (2m 18s vs 2m 15s — noise). Filter drivers intercept regardless of exclusion lists.

**Docker Desktop.** Bind mounts of Windows folders go through the same underlying file-sharing mechanism as raw WSL `/mnt/` access — benchmark numbers were identical, and the Claude Code hang reproduced identically inside a container. Additionally, the reverse direction (Samba *inside* a container, mapped by Windows) is blocked structurally: Windows owns port 445, Docker bridge IPs are not routable from the Windows host, and the Windows SMB client silently rejects the `\\host@port\share` non-default-port syntax (System error 67, with no traffic ever reaching the container).

**SMB in the WSL→Windows direction.** Mounting a Windows share from inside WSL via `cifs` instead of using `/mnt/`: same slowness. The bottleneck is below the protocol layer — NTFS plus filter drivers — so swapping 9P for SMB changes nothing.

**Opening the project from `\\wsl.localhost\` in Unity.** Unity refuses with *"The project is on case sensitive file system"*. WSL's ext4 is case-sensitive; Unity's asset database requires case-insensitivity. The ext4 `casefold` feature could fix this per-directory, but the default WSL ext4 image is built **without** the casefold feature flag, and enabling it requires rebuilding the filesystem.

**`vmIdleTimeout` in `.wslconfig`.** Relevant to a secondary problem (see Keepalive below). Tested with `-1` and with `86400000` (24h): the distro still terminated **within seconds** of the last `wsl.exe` session closing — even with Samba and a dedicated systemd keepalive service running inside. On current WSL (tested on 2.7.3), a distro's lifetime is tied to having an attached `wsl.exe` process, not to internal process activity.

**Disabling the sandbox.** Works — confirms the diagnosis — but surrenders the reason for using WSL in the first place.

## The design

Reverse the direction of sharing. Instead of Linux reaching across a slow bridge into Windows files, the files live on Linux and Windows reaches across a *fast, correct* bridge into them:

```
WSL ext4: ~/dev/project  ──► Claude Code reads natively (sandboxed, fast)
        └─► Samba ──► Windows maps \\<wsl-ip>\dev as Z: ──► Unity/Unreal/VS
```

Both sides see the same bytes. There is no synchronization, because there are no copies.

### Component: Samba configuration

Two non-obvious directives make Windows tooling work, both discovered empirically:

```ini
case sensitive = no          # emulate case-insensitive name resolution
preserve case = yes          # ...while preserving the on-disk casing
acl allow execute always = yes   # report execute permission to Windows clients
```

`case sensitive = no` satisfies Unity's case-sensitivity probe — Samba performs case-insensitive lookups at the protocol layer even though ext4 underneath is case-sensitive. `acl allow execute always` fixes `LoadLibrary`/`CreateProcess` failures ("error code 5", "Access is denied") when Windows executes binaries from the share — Unity's Burst compiler DLLs, `vswhere.exe`, and build toolchains all require it.

NAT networking mode is required: in mirrored mode the distro shares the Windows network stack, where Windows itself owns port 445, and smbd crashes at startup with "Address already in use".

### Component: the keepalive

WSL terminates a distro within seconds of the last attached `wsl.exe` process exiting — regardless of daemons running inside, and regardless of `vmIdleTimeout`. When the distro dies, Samba dies, and the mapped drive disconnects.

The empirically working countermeasure: keep one hidden `wsl.exe -d <distro> -- sleep infinity` process running in the user's Windows session. An attached `wsl.exe` is the one signal WSL's lifecycle manager respects. The process consumes negligible resources, is identifiable by its command line (the mapping script detects an existing one rather than spawning duplicates), and dies naturally at logoff — at which point the VM is *supposed* to shut down.

### Component: IP discovery and the mapping script

In NAT mode the distro's IP changes between VM starts, so any static mapping eventually goes stale. The mapping script (`claudecodewsb-map-drive.ps1`) therefore performs the full sequence on every invocation: ensure keepalive → query `hostname -I` (with retries while the VM boots) → wait for port 445 with a fast TCP probe → delete any stale mapping → map fresh. It runs from two entry points: a scheduled task at login, and a Start Menu "Remount" shortcut for mid-session recovery after `wsl --shutdown` or a Windows update.

Credentials are stored DPAPI-encrypted (`Export-Clixml`), readable only by the same Windows user on the same machine. The password is passed to `net.exe` as a discrete argument (no `cmd /c` string interpolation), so special characters cannot break parsing or inject commands.

### Component: installers

Both installers follow the same contract, shaped by failures observed during testing:

- **State is recorded incrementally**, from the first system modification — not at the end. A failed install leaves a state file marked `in_progress` listing the completed steps, so the uninstaller can clean up partial installs.
- **Backups are taken before modification and never overwritten.** A re-run after a failure reuses the original run's backups, so "restore from backup" always restores the true pre-install state, never an intermediate one.
- **Generated files carry an ownership marker** (`Generated by ClaudeCodeWSB` / state metadata), and the uninstallers refuse to delete configuration they cannot identify as their own.
- **Uninstallers run in best-effort mode** when state is missing entirely: every step checks for its artifact before acting.

## Windows PowerShell 5.1 landmines (for contributors)

All of these caused real failures during development. The scripts work around them; do not reintroduce them.

1. **Native stderr under `ErrorActionPreference = "Stop"`.** Redirecting a native command's stderr (`2>$null`, `2>&1`) converts any stderr text into a *terminating* error. `net use Z: /delete` on a machine with no `Z:` prints "The network connection could not be found" to stderr — and kills the script. All native calls relax EAP locally around the invocation.

2. **`Start-Process -Wait` waits for the entire process tree.** The mapping script spawns the keepalive — a process designed never to exit — so a parent using `-Wait` hangs forever. Child PowerShell invocations use the call operator (`&`) instead, which waits only for the direct child.

3. **`$Host` is a read-only automatic variable.** Using it as a function parameter name throws "Cannot overwrite variable Host" at call time. Use `$ComputerName`.

4. **`?` is valid in variable names.** `"$logPath?"` interpolates the (nonexistent) variable `logPath?` as an empty string. Delimit with braces: `"${logPath}?"`.

5. **BOM-less files are read as ANSI.** A UTF-8 em-dash misread as CP-1252 yields a curly quote, which PS 5.1 accepts as a string delimiter — producing parse errors that point at the end of the file. Repo rule: `.ps1` files are pure ASCII *and* carry a UTF-8 BOM.

6. **`wsl.exe` output may contain interleaved nulls** (UTF-16 capture) and **PowerShell flattens multi-line native output** when coerced to a string. Distro-list parsing must strip nulls *and* preserve array structure.

## Known limitations and future directions

- **The drive's availability is coupled to the WSL VM lifetime.** The keepalive covers normal sessions; explicit shutdowns and Windows updates still require the Remount shortcut. A possible future improvement is a lightweight watcher task that detects a disconnected drive and remaps automatically — deliberately not implemented in v1 to avoid masking real failures.
- **Share name coupling.** The Windows installer must be told the share name if it was customized on the WSL side. Reading it automatically from `testparm -s` output inside the distro is a planned improvement.
- **Ubuntu 24.04 only**, by validation rather than necessity — the approach should work on any systemd-era Debian-family distro, but only 24.04 is tested.
- **ext4 `casefold`** would allow Unity to open `\\wsl.localhost\` paths directly, removing Samba entirely — but requires building the WSL filesystem with the feature flag, which is invasive enough that the Samba layer remains the pragmatic choice.
