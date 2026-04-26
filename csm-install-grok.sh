#!/usr/bin/env bash
# =============================================================================
# csm-install-grok.sh - Container Stack Manager Installer
# =============================================================================

set -euo pipefail

# =============================================================================
# WHAT THIS SCRIPT DOES
# =============================================================================
# - Detect OS package manager
# - Ensure Docker or Podman is installed (offer choice if none found)
# - Create directory structure with correct permissions
# - Install core CSM files (csm.sh, csm.ini, user.conf)
# - Create symlinks: ~/stacks -> CSM_DIR, /usr/local/bin/csm -> csm.sh
# - Verify ownership and permissions

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================
csm_version="0.4.5"
dry_run=0
csm_debug=0
force_install=1  # assume force to avoid prompts

declare -gA user_overrides
csm_gid=2000
readonly CSM_ROOT_DIR="/srv/stacks"
readonly CSM_CONFIGS_DIR="${CSM_ROOT_DIR}/.configs"
readonly CSM_BACKUPS_DIR="${CSM_ROOT_DIR}/.backups"
readonly CSM_SECRETS_DIR="${CSM_ROOT_DIR}/.secrets"
readonly CSM_TEMPLATES_DIR="${CSM_ROOT_DIR}/.templates"

# =============================================================================
# SCRIPT SETUP
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
else
    echo "ERROR: This script must be executed directly, not sourced." >&2
    echo "Run: bash csm-install-grok.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# Privilege check
if [[ "$(id -u)" -eq 0 ]]; then
    var_sudo=""
elif command -v sudo >/dev/null 2>&1; then
    var_sudo="sudo"
else
    printf "This installer requires root or sudo. Neither is available.\n" >&2
    exit 1
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
_tput_safe() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

_color_setup() {
    if [[ -n ${CSM_NO_COLOR:-} || ! -t 1 ]]; then
        red="" grn="" ylw="" blu="" mgn="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    else
        red=$(_tput_safe setaf 1)
        grn=$(_tput_safe setaf 2)
        ylw=$(_tput_safe setaf 3)
        blu=$(_tput_safe setaf 4)
        mgn=$(_tput_safe setaf 5)
        cyn=$(_tput_safe setaf 6)
        wht=$(_tput_safe setaf 7)
        blk=$(_tput_safe setaf 0)
        bld=$(_tput_safe bold)
        uln=$(_tput_safe smul)
        rst=$(_tput_safe sgr0)
    fi
}

_log() {
    local level="${1:-INFO}" message="${2:-}"
    local color
    local prefix=""

    # Add DRY-RUN prefix if in dry-run mode
    if [[ "${dry_run:-0}" == "1" ]]; then prefix="[DRY-RUN] "; fi

    case "$level" in
        EXIT|FAIL)  color="${red}" ;;
        INFO)       color="${cyn}" ;;
        STEP)       color="${mgn}"; if [[ "${csm_debug:-0}" == "0" ]]; then return 0; fi ;;
        PASS)       color="${grn}" ;;
        WARN)       color="${ylw}" ;;
        *)          color="${ylw}"; level="WARN"
                    message="[Unknown log type: '${level}'] $message"
                    ;;
    esac
    printf " %s%s%-4s >> %s%s%s %s<<%s\n" \
        "${color}" "${bld}" "${level}" "${prefix}" "${rst}" "${message}" "${color}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_die() { _log FAIL "$1"; exit 1; }

# =============================================================================
# PLATFORM DETECTION
# =============================================================================
_detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then pkg_mgr="apt-get"
    elif command -v dnf     >/dev/null 2>&1; then pkg_mgr="dnf"
    elif command -v yum     >/dev/null 2>&1; then pkg_mgr="yum"
    elif command -v pacman  >/dev/null 2>&1; then pkg_mgr="pacman"
    else
        _log WARN "Unsupported package manager - install curl, git manually if needed."
        pkg_mgr=""
    fi
    _log STEP "_detect_pkg_manager: detected=$pkg_mgr"
}

_install_pkg() {
    if [[ -z "${pkg_mgr:-}" ]]; then _log WARN "No pkg manager - skipping: $*"; return 0; fi
    _log STEP "_install_pkg: using $pkg_mgr to install: $*"
    case "$pkg_mgr" in
        apt-get)
            _log STEP "_install_pkg: running apt-get update -qq"
            $var_sudo apt-get update -qq
            _log STEP "_install_pkg: running apt-get install -y $*"
            $var_sudo apt-get install -y "$@"
            ;;
        dnf|yum)
            _log STEP "_install_pkg: running $pkg_mgr install -y $*"
            $var_sudo "$pkg_mgr" install -y "$@" ;;
        pacman)
            _log STEP "_install_pkg: running pacman -S --noconfirm $*"
            $var_sudo pacman -S --noconfirm "$@" ;;
    esac
}

# =============================================================================
# CONTAINER RUNTIME DETECTION / INSTALLATION
# =============================================================================
_detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        _log PASS "Docker found: $(docker --version)"
        csm_runtime="docker"
        csm_group="docker"
        _log STEP "_detect_runtime: docker detected"
        return 0
    elif command -v podman >/dev/null 2>&1; then
        _log PASS "Podman found: $(podman --version)"
        csm_runtime="podman"
        csm_group="podman"
        _log STEP "_detect_runtime: podman detected"
        return 0
    fi
    _log STEP "_detect_runtime: no runtime found"
    return 1
}

_install_docker() {
    _log STEP "_install_docker: downloading get.docker.com..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
        || _die "Failed to download Docker installer."
    _log STEP "_install_docker: running installer..."
    $var_sudo sh /tmp/get-docker.sh \
        || _die "Docker installation failed."
    rm -f /tmp/get-docker.sh
    _log PASS "Docker installed: $(docker --version)"
    csm_runtime="docker"
    csm_group="docker"
}

_install_podman() {
    _log STEP "_install_podman: installing via package manager..."
    _install_pkg podman
    _log PASS "Podman installed: $(podman --version)"
    csm_runtime="podman"
    csm_group="podman"
}

_install_runtime() {
    _log STEP "_install_runtime: checking for existing runtime..."
    if _detect_runtime; then
        _log INFO "Container runtime already installed - skipping installation."
        return 0
    fi

    _log WARN "No container runtime found."
    _log INFO "Installing Docker (recommended for most users)."
    _install_docker
}

# =============================================================================
# GROUP AND OWNERSHIP
# =============================================================================
_create_group() {
    csm_gid="${CSM_STACKS_GID:-2000}"
    csm_uid="${CSM_STACKS_UID:-${SUDO_UID:-$(id -u)}}"

    _log STEP "_create_group: checking if group '$csm_group' (GID ${csm_gid}) exists..."

    if ! getent group "$csm_group" >/dev/null 2>&1; then
        _log INFO "Group '$csm_group' does not exist"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create group '$csm_group' with GID $csm_gid"
        else
            _log STEP "_create_group: creating group..."
            $var_sudo groupadd -g "$csm_gid" "$csm_group" \
                && _log INFO "Created group '$csm_group' (GID $csm_gid)" \
                || _die "Failed to create group '$csm_group'"
        fi
    else
        _log INFO "Group '$csm_group' (GID $csm_gid) already exists."
    fi

    # Use the actual GID
    csm_gid="$(getent group "$csm_group" | cut -d: -f3)"
    _log STEP "_create_group: resolved csm_gid=$csm_gid"

    local current_user="${SUDO_USER:-$(id -un)}"
    _log STEP "_create_group: checking if user '$current_user' is in group '$csm_group'..."
    if ! groups "$current_user" 2>/dev/null | grep -qw "$csm_group"; then
        _log WARN "User '$current_user' is not in the '$csm_group' group."
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would add user '$current_user' to group '$csm_group'"
        else
            _log STEP "_create_group: running gpasswd -a $current_user $csm_group"
            $var_sudo gpasswd -a "$current_user" "$csm_group"
            _log INFO "User added. Log out and back in for this to take effect."
        fi
    else
        _log PASS "User '$current_user' is in the '$csm_group' group."
    fi
}

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================
_setup_folders() {
    readonly mode_dirs="770"
    readonly mode_exec="770"
    readonly mode_conf="660"

    _log STEP "_setup_folders: initializing structure at ${CSM_ROOT_DIR}"
    local target_dirs=(
        "$CSM_ROOT_DIR"
        "$CSM_BACKUPS_DIR"
        "$CSM_CONFIGS_DIR"
        "$CSM_SECRETS_DIR"
        "$CSM_TEMPLATES_DIR"
    )
    for dir in "${target_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would create directory '$dir' (mode: $mode_dirs)"
            else
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_dirs" -d "$dir"
                _log INFO "Created directory: $dir"
            fi
        else
            _log INFO "Directory '$dir' already exists"
        fi
    done
    _log INFO "_setup_folders: done"
}

# =============================================================================
# INSTALL FILES
# =============================================================================
_setup_files() {
    _log STEP "_setup_files: installing CSM core files..."

    # Install csm-grok.sh
    if [[ -f "${script_dir}/csm-grok.sh" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would install csm-grok.sh to ${CSM_CONFIGS_DIR}/ (mode: $mode_exec)"
        else
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_exec" -C "${script_dir}/csm-grok.sh" "${CSM_CONFIGS_DIR}/"
            _log INFO "Installed: csm-grok.sh → ${CSM_CONFIGS_DIR}"
        fi
    fi

    # Install csm.ini
    if [[ -f "${script_dir}/csm.ini" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would install csm.ini to ${CSM_CONFIGS_DIR}/ (mode: $mode_conf)"
        else
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" -C "${script_dir}/csm.ini" "${CSM_CONFIGS_DIR}/"
            _log INFO "Installed: csm.ini → ${CSM_CONFIGS_DIR}"
        fi
    fi

    # Create user.conf from csm.ini if not exists
    local user_conf="${CSM_CONFIGS_DIR}/user.conf"
    if [[ ! -f "$user_conf" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create user.conf from csm.ini"
        else
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "${script_dir}/csm.ini" "$user_conf"
            _log INFO "Created user.conf from csm.ini"
        fi
    else
        _log INFO "user.conf already exists"
    fi

    _log INFO "_setup_files: done"
}

# =============================================================================
# SYMLINKS
# =============================================================================
_setup_symlinks() {
    _log STEP "_setup_symlinks: setting up symlinks..."

    # Convenience Link: ~/stacks -> CSM_ROOT_DIR
    local link_source="${HOME}/stacks"
    local link_target="$CSM_ROOT_DIR"

    if [[ -L "$link_source" ]]; then
        if [[ "$(readlink -f "$link_source")" != "$(readlink -f "$link_target")" ]]; then
            _log WARN "Symlink $link_source is misaligned."
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would correct symlink: $link_source -> $link_target"
            else
                rm -f "$link_source"
                ln -s "$link_target" "$link_source"
                _log INFO "Corrected symlink: $link_source"
            fi
        else
            _log INFO "Symlink $link_source is correct"
        fi
    elif [[ ! -e "$link_source" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create symlink: $link_source -> $link_target"
        else
            ln -s "$link_target" "$link_source"
            _log INFO "Created symlink: $link_source"
        fi
    fi

    # Binary Link: /usr/local/bin/csm-grok -> .configs/csm-grok.sh
    local bin_source="/usr/local/bin/csm-grok"
    local bin_target="${CSM_CONFIGS_DIR}/csm-grok.sh"

    if [[ -L "$bin_source" ]]; then
        if [[ "$(readlink -f "$bin_source")" != "$(readlink -f "$bin_target")" ]]; then
            _log WARN "Binary symlink $bin_source is misaligned."
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would correct symlink: $bin_source -> $bin_target"
            else
                $var_sudo ln -sf "$bin_target" "$bin_source"
                _log INFO "Corrected binary symlink: $bin_source"
            fi
        else
            _log INFO "Binary symlink $bin_source is correct"
        fi
    elif [[ ! -e "$bin_source" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create symlink: $bin_source -> $bin_target"
        else
            $var_sudo ln -sf "$bin_target" "$bin_source"
            _log INFO "Created binary symlink: $bin_source"
        fi
    fi
}

# =============================================================================
# VERIFY OWNERSHIP
# =============================================================================
_verify_ownership() {
    _log STEP "_verify_ownership: checking current ownership of ${CSM_ROOT_DIR}..."

    local current_uid current_gid
    current_uid=$(stat -c '%u' "$CSM_ROOT_DIR" 2>/dev/null || stat -f '%u' "$CSM_ROOT_DIR")
    current_gid=$(stat -c '%g' "$CSM_ROOT_DIR" 2>/dev/null || stat -f '%g' "$CSM_ROOT_DIR")
    _log INFO "Current uid:gid: $current_uid:$current_gid, target: $csm_uid:$csm_gid"

    if [[ "$current_uid" != "$csm_uid" || "$current_gid" != "$csm_gid" ]]; then
        _log INFO "Ownership needs to be set"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would run: chown -R ${csm_uid}:${csm_gid} ${CSM_ROOT_DIR}"
        else
            _log STEP "_verify_ownership: running chown -R ${csm_uid}:${csm_gid} ${CSM_ROOT_DIR}"
            $var_sudo chown -R "${csm_uid}:${csm_gid}" "$CSM_ROOT_DIR"
        fi
    else
        _log INFO "Ownership is already correct"
    fi

    local current_perms
    current_perms=$(stat -c '%A' "$CSM_ROOT_DIR" 2>/dev/null || stat -f '%Sp' "$CSM_ROOT_DIR")
    local sgid_bit
    sgid_bit="$(echo "$current_perms" | cut -c6)"
    _log INFO "Current perms: $current_perms, sgid bit: $sgid_bit"

    if [[ "$sgid_bit" != "s" ]]; then
        _log INFO "SGID bit needs to be set"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would run: chmod g+s $CSM_ROOT_DIR"
        else
            _log STEP "_verify_ownership: running chmod g+s $CSM_ROOT_DIR"
            $var_sudo chmod g+s "$CSM_ROOT_DIR"
        fi
    else
        _log INFO "SGID bit is already set"
    fi

    _log INFO "_verify_ownership: done"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    _color_setup

    _log INFO "Container Stack Manager Grok v${csm_version} - installer starting"
    _log INFO "Install path: ${CSM_ROOT_DIR}"

    _detect_pkg_manager
    _create_group
    _install_runtime
    _setup_folders
    _setup_files
    _setup_symlinks
    _verify_ownership

    echo ""
    _log PASS "CSM Grok installation complete!"
    echo ""
    _log INFO "Next steps:"
    _log INFO "  1. Edit config files in: ${CSM_CONFIGS_DIR}/"
    _log INFO "  2. View your stacks: ${CSM_ROOT_DIR}/"
    _log INFO "  3. Get started: csm-grok --help"
    # Check if the invoking user is in the container group
    local check_user="${SUDO_USER:-$(id -un)}"
    if ! groups "$check_user" 2>/dev/null | grep -qw "$csm_group"; then
        _log WARN "Remember to log out and back in so your $csm_group group membership takes effect for CSM Grok."
    fi
}

main "$@"