#!/bin/bash
# ClaudeCodeWSB - WSL-side installer
#
# Sets up Samba to share a directory from this WSL distro back to Windows,
# installs Claude Code with all sandbox dependencies, and configures WSL boot
# so Samba auto-starts.
#
# Usage:
#   ./install.sh
#
# Run as your normal user (not root). Sudo will be used where needed.
#
# Safe to re-run after a failed install: backups from the first run are
# preserved and reused, and completed steps are tracked in the state file.

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_FILE="$HOME/.claudecodewsb-install-state"
readonly REQUIRED_UBUNTU_VERSION="24.04"

# Locate the files directory — support both the repo layout (files/ subdir)
# and a flat layout where everything was copied into one directory.
if [ -f "$SCRIPT_DIR/files/smb.conf.template" ]; then
    readonly FILES_DIR="$SCRIPT_DIR/files"
elif [ -f "$SCRIPT_DIR/smb.conf.template" ]; then
    readonly FILES_DIR="$SCRIPT_DIR"
else
    echo "ERROR: smb.conf.template not found." >&2
    echo "Expected it at either:" >&2
    echo "  $SCRIPT_DIR/files/smb.conf.template" >&2
    echo "  $SCRIPT_DIR/smb.conf.template" >&2
    echo "Make sure you copied all installer files." >&2
    exit 1
fi

# Backup dir: reuse from a previous incomplete install so a re-run after a
# failure restores the TRUE originals, not the half-modified files.
BACKUP_DIR="$HOME/.claudecodewsb-backups/$(date +%Y%m%d-%H%M%S)"
if [ -f "$STATE_FILE" ] && grep -q "^INSTALL_STATUS=in_progress" "$STATE_FILE" 2>/dev/null; then
    PREVIOUS_BACKUP=$(grep "^BACKUP_DIR=" "$STATE_FILE" | cut -d= -f2- || true)
    if [ -n "${PREVIOUS_BACKUP:-}" ] && [ -d "$PREVIOUS_BACKUP" ]; then
        BACKUP_DIR="$PREVIOUS_BACKUP"
    fi
fi
readonly BACKUP_DIR

# Colors for output (only if stdout is a terminal)
if [ -t 1 ]; then
    readonly C_RED="$(tput setaf 1)"
    readonly C_GREEN="$(tput setaf 2)"
    readonly C_YELLOW="$(tput setaf 3)"
    readonly C_BLUE="$(tput setaf 4)"
    readonly C_BOLD="$(tput bold)"
    readonly C_RESET="$(tput sgr0)"
else
    readonly C_RED=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_BLUE=""
    readonly C_BOLD=""
    readonly C_RESET=""
fi

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
info()    { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()      { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()    { echo "${C_YELLOW}!${C_RESET} $*"; }
err()     { echo "${C_RED}✗${C_RESET} $*" >&2; }
header()  { echo; echo "${C_BOLD}$*${C_RESET}"; echo "${C_BOLD}$(printf '%*s' "${#1}" '' | tr ' ' '=')${C_RESET}"; }
prompt()  { local p="$1"; local default="${2:-}"; local result
    if [ -n "$default" ]; then
        read -p "$p [$default]: " result
        echo "${result:-$default}"
    else
        read -p "$p: " result
        echo "$result"
    fi
}

# -----------------------------------------------------------------------------
# Install state tracking (incremental — written as steps complete, so the
# uninstaller can clean up even after a partial/failed install)
# -----------------------------------------------------------------------------
init_state() {
    cat > "$STATE_FILE" <<EOF
# ClaudeCodeWSB install state — used by uninstaller. Do not edit.
INSTALL_DATE=$(date -Iseconds)
INSTALL_STATUS=in_progress
BACKUP_DIR=$BACKUP_DIR
USERNAME=$USERNAME
WORKSPACE_PATH=$WORKSPACE_PATH
SHARE_NAME=$SHARE_NAME
INSTALLED_PACKAGES=samba,samba-common-bin,bubblewrap,socat,nodejs,git-lfs
INSTALLED_NPM_GLOBALS=@anthropic-ai/claude-code
EOF
}

mark_step() {
    # Append a step-completion marker, but only once
    if ! grep -q "^COMPLETED_$1=true" "$STATE_FILE" 2>/dev/null; then
        echo "COMPLETED_$1=true" >> "$STATE_FILE"
    fi
}

finish_state() {
    sed -i 's/^INSTALL_STATUS=in_progress/INSTALL_STATUS=complete/' "$STATE_FILE"
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        err "Don't run this as root."
        err "Run as your normal user; sudo will be used where needed."
        exit 1
    fi
}

check_wsl() {
    if [ ! -f /proc/version ] || ! grep -qi microsoft /proc/version; then
        err "This script is for WSL only. Doesn't look like WSL here."
        exit 1
    fi
    if ! grep -qi "WSL2\|microsoft-standard" /proc/version 2>/dev/null; then
        warn "WSL version detection inconclusive. This setup requires WSL2."
        warn "If you're on WSL1, the script may fail or behave incorrectly."
        local cont
        cont=$(prompt "Continue anyway? (y/N)" "N")
        case "$cont" in
            [Yy]*) ;;
            *) exit 1 ;;
        esac
    fi
}

check_distro() {
    if [ ! -f /etc/os-release ]; then
        err "Can't determine distro (/etc/os-release missing)."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
        err "This script supports Ubuntu only. Detected: ${ID:-unknown}"
        exit 1
    fi
    if [ "${VERSION_ID:-}" != "$REQUIRED_UBUNTU_VERSION" ]; then
        warn "This script is tested on Ubuntu $REQUIRED_UBUNTU_VERSION."
        warn "Detected: ${VERSION_ID:-unknown}"
        local cont
        cont=$(prompt "Continue anyway? (y/N)" "N")
        case "$cont" in
            [Yy]*) ;;
            *) exit 1 ;;
        esac
    fi
}

check_sudo() {
    info "Verifying sudo access (you may be prompted for your password)..."
    if ! sudo -v; then
        err "Sudo access required."
        exit 1
    fi
}

check_resume() {
    if [ -f "$STATE_FILE" ]; then
        if grep -q "^INSTALL_STATUS=complete" "$STATE_FILE" 2>/dev/null; then
            warn "A previous complete installation was detected."
            warn "Re-running will overwrite the current configuration."
        elif grep -q "^INSTALL_STATUS=in_progress" "$STATE_FILE" 2>/dev/null; then
            warn "A previous INCOMPLETE installation was detected."
            warn "This run will resume/repair it, reusing the original backups."
        fi
        local cont
        cont=$(prompt "Continue? (y/N)" "N")
        case "$cont" in
            [Yy]*) ;;
            *) exit 0 ;;
        esac
    fi
}

# -----------------------------------------------------------------------------
# Configuration gathering
# -----------------------------------------------------------------------------
gather_config() {
    header "Configuration"

    USERNAME=$(whoami)
    info "Setting up for user: $USERNAME"
    echo

    echo "Where should your projects live inside WSL?"
    echo "This directory will be served via Samba so Windows can mount it."
    WORKSPACE_PATH=$(prompt "Path" "$HOME/dev")
    WORKSPACE_PATH="${WORKSPACE_PATH/#\~/$HOME}"
    echo

    echo "What name should the Samba share have?"
    echo "Windows will mount this as \\\\<wsl-ip>\\<sharename>"
    SHARE_NAME=$(prompt "Share name" "dev")
    echo

    echo "Set a Samba password (Windows will use this to connect to the share)."
    echo "${C_YELLOW}Use a strong password — Samba may be reachable on your local network.${C_RESET}"
    while true; do
        read -s -p "Samba password: " SMB_PASSWORD
        echo
        read -s -p "Confirm password: " SMB_CONFIRM
        echo
        if [ -z "$SMB_PASSWORD" ]; then
            warn "Empty password not allowed."
            continue
        fi
        if [ "$SMB_PASSWORD" != "$SMB_CONFIRM" ]; then
            warn "Passwords don't match."
            continue
        fi
        break
    done
    echo

    echo "${C_BOLD}Summary:${C_RESET}"
    echo "  User:         $USERNAME"
    echo "  Workspace:    $WORKSPACE_PATH"
    echo "  Share name:   $SHARE_NAME"
    echo "  Will install: Samba, bubblewrap, socat, Git, Git LFS, Node.js LTS, Claude Code"
    echo
    local confirm
    confirm=$(prompt "Proceed with installation? (y/N)" "N")
    case "$confirm" in
        [Yy]*) ;;
        *) info "Aborted."; exit 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# Backup existing configs before modifying
# -----------------------------------------------------------------------------
backup_if_exists() {
    local path="$1"
    if [ -e "$path" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_path="$BACKUP_DIR$(echo "$path" | tr '/' '_')"
        if [ -e "$backup_path" ]; then
            # A backup from a previous (failed) run exists — keep it, it's the
            # true original. Don't overwrite with the possibly-modified current.
            warn "Backup for $path already exists from a previous run — keeping the original."
            return 0
        fi
        sudo cp -a "$path" "$backup_path"
        ok "Backed up $path → $backup_path"
        return 0
    fi
    return 1
}

check_for_conflicts() {
    header "Checking for existing configurations"

    local conflicts=0

    if [ -f /etc/samba/smb.conf ]; then
        if grep -q "ClaudeCodeWSB" /etc/samba/smb.conf 2>/dev/null; then
            info "Existing smb.conf was generated by ClaudeCodeWSB — will be regenerated."
        elif grep -qE '^\s*\[' /etc/samba/smb.conf 2>/dev/null && \
             grep -vE '^\s*\[(global|homes|printers|print\$)\]' /etc/samba/smb.conf | grep -qE '^\s*\['; then
            warn "Existing /etc/samba/smb.conf has custom shares."
            conflicts=$((conflicts + 1))
        else
            info "Existing /etc/samba/smb.conf appears to be default — will be replaced."
        fi
    fi

    if [ -f /etc/wsl.conf ]; then
        if grep -qE "^\s*command\s*=" /etc/wsl.conf 2>/dev/null && \
           ! grep -q "ClaudeCodeWSB" /etc/wsl.conf 2>/dev/null; then
            warn "Existing /etc/wsl.conf has a boot command — will be merged with ours."
            conflicts=$((conflicts + 1))
        fi
    fi

    if [ "$conflicts" -gt 0 ]; then
        warn "Existing configs will be backed up to $BACKUP_DIR before modification."
        local cont
        cont=$(prompt "Continue? (y/N)" "N")
        case "$cont" in
            [Yy]*) ;;
            *) exit 1 ;;
        esac
    else
        ok "No conflicts detected."
    fi
}

# -----------------------------------------------------------------------------
# Install system packages
# -----------------------------------------------------------------------------
install_packages() {
    header "Installing system packages"

    info "Updating apt index..."
    sudo apt-get update -qq

    info "Installing core dependencies..."
    sudo apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg git git-lfs ripgrep less procps \
        bubblewrap socat \
        samba samba-common-bin

    # Initialize Git LFS for this user. Game projects very commonly track art,
    # audio, and other binaries with LFS; without it, git in WSL hashes the raw
    # binary instead of the LFS pointer and reports phantom "modified" files
    # that a Windows git (which has LFS) considers clean.
    git lfs install >/dev/null 2>&1 || warn "git lfs install reported an issue; run 'git lfs install' manually if LFS files misbehave."

    ok "System packages installed."
    mark_step "PACKAGES"
}

install_nodejs() {
    header "Installing Node.js LTS"

    if command -v node >/dev/null 2>&1; then
        local node_version
        node_version=$(node --version)
        info "Node already installed: $node_version"
        local node_major
        node_major=$(echo "$node_version" | sed 's/^v\([0-9]*\).*/\1/')
        if [ "$node_major" -ge 18 ]; then
            ok "Node version is sufficient (>= 18)."
            mark_step "NODEJS"
            return 0
        fi
        warn "Node version $node_version is too old for Claude Code (need >= 18)."
        local update
        update=$(prompt "Update Node via NodeSource? (y/N)" "N")
        case "$update" in
            [Yy]*) ;;
            *) err "Cannot proceed with outdated Node."; exit 1 ;;
        esac
    fi

    info "Installing Node.js LTS via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs

    ok "Node installed: $(node --version)"
    mark_step "NODEJS"
}

install_claude_code() {
    header "Installing Claude Code"

    local npm_prefix="$HOME/.npm-global"
    mkdir -p "$npm_prefix"
    npm config set prefix "$npm_prefix"

    local bashrc_line='export PATH="$HOME/.npm-global/bin:$PATH"'
    if ! grep -qF "$bashrc_line" "$HOME/.bashrc"; then
        echo "" >> "$HOME/.bashrc"
        echo "# Added by ClaudeCodeWSB installer" >> "$HOME/.bashrc"
        echo "$bashrc_line" >> "$HOME/.bashrc"
        ok "Added npm-global to PATH in ~/.bashrc"
    fi

    export PATH="$npm_prefix/bin:$PATH"

    info "Installing @anthropic-ai/claude-code (this may take a minute)..."
    npm install -g @anthropic-ai/claude-code

    if command -v claude >/dev/null 2>&1; then
        ok "Claude Code installed: $(claude --version)"
    else
        warn "Claude Code installed but 'claude' not yet on PATH (restart shell after install)."
    fi
    mark_step "CLAUDE_CODE"
}

# -----------------------------------------------------------------------------
# Configure Samba
# -----------------------------------------------------------------------------
configure_samba() {
    header "Configuring Samba"

    mkdir -p "$WORKSPACE_PATH"
    ok "Workspace directory: $WORKSPACE_PATH"

    backup_if_exists /etc/samba/smb.conf

    info "Writing /etc/samba/smb.conf..."
    sudo cp "$FILES_DIR/smb.conf.template" /etc/samba/smb.conf
    sudo sed -i "s|__SHARE_NAME__|$SHARE_NAME|g" /etc/samba/smb.conf
    sudo sed -i "s|__WORKSPACE_PATH__|$WORKSPACE_PATH|g" /etc/samba/smb.conf
    sudo sed -i "s|__USERNAME__|$USERNAME|g" /etc/samba/smb.conf

    if ! sudo testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
        err "Generated smb.conf is invalid. Check /etc/samba/smb.conf manually."
        exit 1
    fi
    ok "Samba config valid."
    mark_step "SAMBA_CONFIG"

    info "Setting Samba password for user '$USERNAME'..."
    echo -e "$SMB_PASSWORD\n$SMB_PASSWORD" | sudo smbpasswd -a -s "$USERNAME" >/dev/null
    sudo smbpasswd -e "$USERNAME" >/dev/null
    ok "Samba user configured."
    mark_step "SAMBA_USER"
}

# -----------------------------------------------------------------------------
# Configure WSL boot
# -----------------------------------------------------------------------------
configure_wsl_boot() {
    header "Configuring WSL boot"

    backup_if_exists /etc/wsl.conf

    info "Writing /etc/wsl.conf..."

    local existing_command=""
    if [ -f /etc/wsl.conf ] && ! grep -q "ClaudeCodeWSB" /etc/wsl.conf; then
        existing_command=$(grep -E '^\s*command\s*=' /etc/wsl.conf 2>/dev/null | sed -E 's/^\s*command\s*=\s*//' || true)
    fi

    local boot_command="service smbd start && service nmbd start"
    if [ -n "$existing_command" ] && [[ "$existing_command" != *"smbd"* ]]; then
        warn "Existing wsl.conf has a boot command; combining with ours."
        boot_command="$existing_command && $boot_command"
    fi

    sudo tee /etc/wsl.conf >/dev/null <<EOF
# Generated by ClaudeCodeWSB installer
[boot]
command = $boot_command

[user]
default = $USERNAME
EOF

    ok "WSL boot configured (Samba will auto-start)."
    mark_step "WSL_BOOT"
}

# -----------------------------------------------------------------------------
# Start Samba immediately
# -----------------------------------------------------------------------------
start_samba() {
    header "Starting Samba"

    sudo service smbd restart
    sudo service nmbd restart

    if sudo ss -tlnp | grep -q ':445'; then
        ok "Samba is running (listening on port 445)."
    else
        err "Samba doesn't appear to be listening on 445."
        err "Check 'sudo service smbd status' for details."
        exit 1
    fi
    mark_step "SAMBA_STARTED"
}

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
print_summary() {
    local wsl_ip
    wsl_ip=$(hostname -I | awk '{print $1}')

    header "Setup complete!"

    echo
    echo "${C_GREEN}WSL-side setup is done.${C_RESET} Next steps:"
    echo
    echo "${C_BOLD}1. Note the connection details:${C_RESET}"
    echo "   WSL IP (changes on reboot): $wsl_ip"
    echo "   Share name:                 $SHARE_NAME"
    echo "   Samba username:             $USERNAME"
    echo
    echo "${C_BOLD}2. Test from Windows PowerShell:${C_RESET}"
    echo "   net use Z: \\\\$wsl_ip\\$SHARE_NAME /user:$USERNAME"
    echo "   (it will prompt for the Samba password you just set)"
    echo
    echo "${C_BOLD}3. For automatic mounting at Windows login,${C_RESET}"
    echo "   run the Windows installer from this repo:"
    echo "   powershell -ExecutionPolicy Bypass -File windows\\install-windows.ps1"
    echo
    echo "${C_BOLD}4. To use Claude Code:${C_RESET}"
    echo "   In your CURRENT shell (the PATH change is not yet active), run:"
    echo "     ${C_GREEN}export PATH=\"\$HOME/.npm-global/bin:\$PATH\"${C_RESET}"
    echo "   Then:"
    echo "     cd $WORKSPACE_PATH/<your-project>"
    echo "     claude"
    echo
    echo "   New WSL shells (after this one) will pick up the PATH automatically."
    echo "   First Claude Code run will prompt for OAuth authentication."
    echo
    echo "If something goes wrong, see TROUBLESHOOTING.md or run uninstall.sh"
    echo "to restore your previous configuration."
    echo
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    header "ClaudeCodeWSB - WSL-side installer"

    check_not_root
    check_wsl
    check_distro
    check_sudo
    check_resume

    gather_config
    init_state
    check_for_conflicts

    install_packages
    install_nodejs
    install_claude_code

    configure_samba
    configure_wsl_boot
    start_samba

    finish_state
    print_summary
}

main "$@"
