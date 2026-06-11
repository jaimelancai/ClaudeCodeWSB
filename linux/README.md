# WSL-side installer

These scripts configure your WSL2 Ubuntu distro to:

1. Run Samba, sharing a directory of your choice back to Windows
2. Install Claude Code with all sandbox dependencies (bubblewrap, socat)
3. Auto-start Samba whenever WSL boots
4. Make file ownership / permissions / case-handling correct so Unity and other Windows-side tools can use the share without errors

## Requirements

- WSL2 with Ubuntu 24.04
- Sudo access in WSL
- Internet access (to install packages and Claude Code)

## Install

Run as your normal user (not root):

```bash
cd ClaudeCodeWSB/wsl
chmod +x install.sh uninstall.sh
./install.sh
```

The script is interactive. It will:

- Verify prerequisites (WSL2, Ubuntu 24.04, sudo)
- Ask where your projects should live
- Ask for a Samba password (used by Windows to connect)
- Detect any conflicts with existing Samba/WSL configs and back them up
- Install packages, Claude Code, and configure Samba
- Print next-steps for the Windows side

After it finishes, restart your shell (or `source ~/.bashrc`) so `claude` is on your PATH.

## What gets modified on your system

| What | Where |
|---|---|
| Samba config | `/etc/samba/smb.conf` (existing backed up) |
| WSL boot config | `/etc/wsl.conf` (existing backed up) |
| Samba user/password | `/var/lib/samba/private/passdb.tdb` |
| PATH | One line added to `~/.bashrc` |
| Node packages | `~/.npm-global/` (user-owned, no sudo needed) |
| Workspace dir | Wherever you specified (default `~/dev`) |
| Install state | `~/.claudecodewsb-install-state` (used by uninstaller) |
| Backups | `~/.claudecodewsb-backups/<timestamp>/` |

System packages installed via apt: `samba`, `samba-common-bin`, `bubblewrap`, `socat`, `nodejs`, plus their dependencies. These are not removed by uninstall unless you explicitly choose to.

## Uninstall

```bash
./uninstall.sh
```

Restores the original Samba and WSL configs from the backups, removes the Samba user, removes the PATH entry from `.bashrc`, and optionally uninstalls system packages and Claude Code (asks first — you may want to keep them).

Your workspace directory is **never deleted by uninstall** — your projects are safe.

After uninstalling, run `wsl --shutdown` from PowerShell so the next WSL boot picks up the restored `/etc/wsl.conf`.

## Troubleshooting

**The script aborts saying "Ubuntu 24.04 required."**

The script is tested on Ubuntu 24.04. You can continue at your own risk on other versions — it'll prompt. If you're on Ubuntu 22.04, things mostly work but Samba defaults differ slightly.

**Sudo prompt times out / install fails partway.**

Re-run the installer. It's designed to be safe to run twice — backups won't be overwritten, and the apt steps are idempotent.

**Claude Code installed but `claude --version` says "command not found."**

You need to restart your shell or run `source ~/.bashrc` so the new PATH takes effect.

**"Workspace already has files in it."**

The installer doesn't touch the workspace contents. If the directory already exists with content, that's preserved — Samba just exposes it as the share.

**`smbpasswd` errors during install.**

Usually means the Samba password backend isn't initialized. Re-run the installer; the second run will succeed because Samba's first start has now created the necessary database files.

See [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) for more.

## Security notes

- The Samba share is exposed on whatever interfaces WSL's network has access to. In typical NAT-mode WSL2, that's just `localhost` on the host side, plus the WSL-internal subnet.
- If you've configured WSL with mirrored networking or your machine is on a LAN, Samba may be reachable to other devices on that network. Use a strong password.
- The Samba password is separate from your Linux login password and is stored in `/var/lib/samba/private/`. Linux file permissions protect it from other local users.
- Backups in `~/.claudecodewsb-backups/` contain the *previous* `/etc/samba/smb.conf` (if any) which may include older share definitions. Review and remove backups if they contain sensitive info you don't want preserved.
