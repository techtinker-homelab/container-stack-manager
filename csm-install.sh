#!/usr/bin/env bash
# =============================================================================
# csm-install.sh  –  Container Stack Manager Installer
# =============================================================================
# What this script does (in order):
#   1.  Validate root / sudo access
#   2.  Detect OS package manager
#   3.  Detect or install container runtime (Docker or Podman)
#   4.  Check / start the container service
#   5.  Check / create the docker user + group (UID/GID 2000, Docker only)
#   6.  Create the CSM directory structure with correct permissions
#   7.  Install core CSM files
#   8.  Create ~/stacks symlink pointing to CSM_ROOT_DIR
#   9.  Symlink /usr/local/bin/csm → CSM_ROOT_DIR/csm.sh
#  10.  Set final ownership
# =============================================================================

set -euo pipefail

readonly INSTALLER_VERSION="1.1.0"

_runtime=""   # set by _detect_container_runtime or _install_container_runtime

# =============================================================================
# 0. HELPERS
# =============================================================================

_tput_safe() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

_color_setup() {
    if [[ -t 1 ]]; then
        red=$(_tput_safe setaf 1)
        grn=$(_tput_safe setaf 2)
        ylw=$(_tput_safe setaf 3)
        blu=$(_tput_safe setaf 4)
        prp=$(_tput_safe setaf 5)
        cyn=$(_tput_safe setaf 6)
        wht=$(_tput_safe setaf 7)
        blk=$(_tput_safe setaf 0)
        bld=$(_tput_safe bold)
        uln=$(_tput_safe smul)
        rst=$(_tput_safe sgr0)
    else
        red="" grn="" ylw="" blu="" prp="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    fi
}
_color_setup

_log() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        FAIL) printf "%s FAIL  >> %s%s\n" "${red}${bld}" "${message}" "${rst}" >&2 ;;
        WARN) printf "%s WARN  >> %s%s\n" "${ylw}${bld}" "${message}" "${rst}" >&2 ;;
        INFO) printf "%s INFO  >> %s%s\n" "${cyn}${bld}" "${message}" "${rst}" ;;
        PASS) printf "%s PASS  >> %s%s\n" "${grn}${bld}" "${message}" "${rst}" ;;
        STEP) printf "%s -- %s%s\n" "${blu}${bld}" "${message}" "${rst}" ;;
        *)    printf "%s DEBUG >> %s%s\n" "${blu}${bld}" "${message}" "${rst}" ;;
    esac
}

_die()     { _log FAIL "$1"; exit 1; }

_confirm_yes() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    [[ -z "${reply}" || "${reply,,}" == "y" ]]
}

_confirm_no() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" reply
    [[ "${reply,,}" == "y" ]]
}

# =============================================================================
# 1. PRIVILEGE CHECK
# =============================================================================

if [[ "$(id -u)" -eq 0 ]]; then
    var_sudo=""
    running_as_root=true
elif command -v sudo >/dev/null 2>&1; then
    var_sudo="sudo"
    running_as_root=false
else
    _die "This installer requires root or sudo. Neither is available."
fi

# =============================================================================
# 2. LOCATE SCRIPT + SOURCE FILES
# =============================================================================

readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# =============================================================================
# 3. CONFIGURATION  (override via env vars before calling the script)
# =============================================================================

export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
csm_stacks="${CSM_STACKS_DIR:-${CSM_ROOT_DIR}}"
csm_backup="${CSM_BACKUP_DIR:-${CSM_ROOT_DIR}/.backup}"
csm_common="${CSM_COMMON_DIR:-${CSM_ROOT_DIR}/.common}"
csm_configs="${CSM_CONFIGS_DIR:-${csm_common}/configs}"
csm_secrets="${CSM_SECRETS_DIR:-${csm_common}/secrets}"

# Owner — when run via sudo, use the invoking user; else current user
csm_owner="${SUDO_USER:-$(id -un)}"
csm_group="docker"   # default, overridden after runtime detection
csm_uid="${SUDO_UID:-$(id -u)}"
csm_gid=2000         # default, overridden by _create_runtime_group

readonly link_path="${HOME}/stacks"
readonly bin_link="/usr/local/bin/csm"

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_dir="775"    # directories: rwxrwxr-x
readonly mode_exec="770"   # executables: rwxrwx---
readonly mode_conf="660"   # config files: rw-rw----
readonly mode_auth="600"   # secrets:      rw-------

# Files to install: source → destination directory
declare -A files_to_install=(
    ["${script_dir}/csm.sh"]="${CSM_ROOT_DIR}/"
    ["${script_dir}/csm-install.sh"]="${csm_common}/"
)
# example.conf → default.conf (only if default.conf doesn't already exist)
[[ -f "${script_dir}/example.conf" ]] && \
    files_to_install["${script_dir}/example.conf"]="${csm_configs}/"
# example.env is optional
[[ -f "${script_dir}/example.env" ]] && \
    files_to_install["${script_dir}/example.env"]="${csm_common}/"

# =============================================================================
# 4. PLATFORM DETECTION
# =============================================================================

_detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then pkg_mgr="apt-get"
    elif command -v dnf     >/dev/null 2>&1; then pkg_mgr="dnf"
    elif command -v yum     >/dev/null 2>&1; then pkg_mgr="yum"
    elif command -v pacman  >/dev/null 2>&1; then pkg_mgr="pacman"
    else
        _log WARN "Unsupported package manager – install curl, git manually if needed."
        pkg_mgr=""
    fi
}

_install_pkg() {
    [[ -z "${pkg_mgr:-}" ]] && { _log WARN "No pkg manager – skipping: $*"; return 0; }
    case "$pkg_mgr" in
        apt-get)
            $var_sudo apt-get update -qq
            $var_sudo apt-get install -y "$@"
            ;;
        dnf|yum) $var_sudo "$pkg_mgr" install -y "$@" ;;
        pacman)  $var_sudo pacman -S --noconfirm "$@" ;;
    esac
}

_get_group() {
    local file="$1"
    stat -c '%G' "$file" 2>/dev/null || stat -f '%Sg' "$file"
}

_get_perms() {
    local file="$1"
    stat -c '%A' "$file" 2>/dev/null || stat -f '%Sp' "$file"
}

# =============================================================================
# 5. CONTAINER RUNTIME DETECTION / INSTALLATION
# =============================================================================

_detect_container_runtime() {
    if command -v docker >/dev/null 2>&1; then
        _log PASS "Docker found: $(docker --version)"
        _runtime="docker"
        return 0
    elif command -v podman >/dev/null 2>&1; then
        _log PASS "Podman found: $(podman --version)"
        _runtime="podman"
        return 0
    fi
    return 1
}

_install_docker() {
    _log INFO "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
        || _die "Failed to download Docker installer."
    $var_sudo sh /tmp/get-docker.sh \
        || _die "Docker installation failed."
    rm -f /tmp/get-docker.sh
    _log PASS "Docker installed: $(docker --version)"
    _runtime="docker"
}

_install_podman() {
    _log INFO "Installing Podman..."
    _install_pkg podman
    _log PASS "Podman installed: $(podman --version)"
    _runtime="podman"
}

_install_container_runtime() {
    if _detect_container_runtime; then
        _log INFO "Container runtime already installed – skipping installation."
        return 0
    fi

    _log WARN "No container runtime found."
    _log INFO "Which would you like to install?"
    _log INFO "  1) Docker  (recommended for most users)"
    _log INFO "  2) Podman  (daemonless, rootless by default)"

    local choice=""
    read -r -p "${ylw}${bld} Select [1/2]: ${rst}" choice
    case "$choice" in
        1|docker) _install_docker ;;
        2|podman) _install_podman ;;
        "")       _install_docker ;;
        *)        _die "Invalid choice. Aborting." ;;
    esac
}

# =============================================================================
# 6. CONTAINER SERVICE CHECK
# =============================================================================

_check_container_service() {
    case "$_runtime" in
        docker)
            _log STEP "Checking Docker service..."
            if ! command -v systemctl >/dev/null 2>&1; then
                _log WARN "systemctl not found – skipping service check."
                return 0
            fi
            if systemctl is-active --quiet docker; then
                _log PASS "Docker service is running."
                return 0
            fi
            _log WARN "Docker service is not running."
            _confirm_yes "Start Docker now?" && {
                $var_sudo systemctl start docker
                systemctl is-active --quiet docker \
                    && _log PASS "Docker started." \
                    || _die "Failed to start Docker. Check: journalctl -u docker"
            }
            ;;
        podman)
            _log STEP "Checking Podman socket..."
            if ! command -v systemctl >/dev/null 2>&1; then
                _log WARN "systemctl not found – skipping service check."
                return 0
            fi
            if systemctl is-active --quiet podman.socket 2>/dev/null; then
                _log PASS "Podman socket is active."
                return 0
            fi
            _log WARN "Podman socket is not active (optional for rootless)."
            _confirm_yes "Enable Podman socket?" && {
                $var_sudo systemctl enable --now podman.socket
                _log PASS "Podman socket enabled."
            }
            ;;
    esac
}

# =============================================================================
# 7. DOCKER USER / GROUP  (UID/GID 2000, Docker only)
# =============================================================================

_create_runtime_group() {
    local gid=2000

    if ! getent group "$gid" >/dev/null 2>&1; then
        $var_sudo groupadd -g "$gid" "$csm_group" \
            && _log INFO "Created group '$csm_group' (GID $gid)" \
            || _die "Failed to create group '$csm_group'"
    else
        _log INFO "Group '$csm_group' (GID $gid) already exists."
    fi

    # Use the actual GID (may differ if group already existed with different GID)
    csm_gid="$(getent group "$csm_group" | cut -d: -f3)"

    local current_user="${SUDO_USER:-$(id -un)}"
    if ! groups "$current_user" 2>/dev/null | grep -qw "$csm_group"; then
        _log WARN "User '$current_user' is not in the '$csm_group' group."
        _confirm_yes "Add '$current_user' to '$csm_group'?" && {
            $var_sudo gpasswd -a "$current_user" "$csm_group"
            _log INFO "User added. Log out and back in for this to take effect."
        }
    else
        _log PASS "User '$current_user' is in the '$csm_group' group."
    fi
}

# =============================================================================
# 8. DIRECTORY STRUCTURE
# =============================================================================

_install_dir() {
    local tgt="$1" mode="$2"
    if [[ ! -d "$tgt" ]]; then
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -d "$tgt"
        _log INFO "Created: $tgt"
    else
        _log INFO "Exists:  $tgt"
    fi
}

_install_file() {
    local src="$1" dest_dir="$2" mode="$3"
    if [[ -f "$src" ]]; then
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" "$src" "$dest_dir/"
        _log INFO "Installed: $(basename "$src") → $dest_dir"
    else
        _log WARN "Source file missing – skipping: $src"
    fi
}

_setup_directories() {
    _log STEP "Creating CSM directory structure under ${CSM_ROOT_DIR}..."
    _install_dir "$CSM_ROOT_DIR" "$mode_dir"
    _install_dir "$csm_backup"   "$mode_dir"
    _install_dir "$csm_common"   "$mode_dir"
    _install_dir "$csm_stacks"   "$mode_dir"
    _install_dir "$csm_configs"  "$mode_dir"
    _install_dir "$csm_secrets"  "$mode_dir"
}

_setup_files() {
    _log STEP "Installing CSM core files..."
    for src in "${!files_to_install[@]}"; do
        local dest_dir="${files_to_install[$src]}"
        local mode
        [[ "$src" == *.conf ]] && mode="$mode_conf" || mode="$mode_exec"
        _install_file "$src" "$dest_dir" "$mode"
    done

    # Rename example.conf → default.conf (only on fresh install)
    local example_conf="${csm_configs}/example.conf"
    local default_conf="${csm_configs}/default.conf"
    if [[ -f "$example_conf" && ! -f "$default_conf" ]]; then
        $var_sudo mv "$example_conf" "$default_conf"
        _log INFO "Renamed example.conf → default.conf"
    fi

    # Patch detected runtime values into default.conf
    if [[ -f "$default_conf" ]]; then
        sed -i "s/^CSM_CONTAINER_RUNTIME=.*/CSM_CONTAINER_RUNTIME=${_runtime}/" "$default_conf"
        sed -i "s/^CSM_STACKS_GID=.*/CSM_STACKS_GID=${csm_gid}/" "$default_conf"
        _log INFO "Patched CSM_CONTAINER_RUNTIME=${_runtime} and CSM_STACKS_GID=${csm_gid} into default.conf"
    fi
}

# =============================================================================
# 9. SYMLINKS
# =============================================================================

_setup_symlinks() {
    _log STEP "Setting up symlinks..."

    # ~/stacks  → CSM_ROOT_DIR
    local target_dir="$CSM_ROOT_DIR"
    if [[ ! -e "$link_path" && ! -L "$link_path" ]]; then
        ln -s "$target_dir" "$link_path"
        _log INFO "Created symlink: $link_path → $target_dir"
    elif [[ -L "$link_path" ]]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if [[ "$current_target" != "$target_dir" ]]; then
            _log WARN "Symlink $link_path points to $current_target (expected $target_dir)"
            _confirm_no "Update symlink to point to $target_dir?" && {
                rm -f "$link_path"
                ln -s "$target_dir" "$link_path"
                _log INFO "Symlink updated."
            }
        else
            _log PASS "Symlink $link_path is correct."
        fi
    else
        _log WARN "$link_path exists and is not a symlink – leaving it alone."
    fi

    # /usr/local/bin/csm  → CSM_ROOT_DIR/csm.sh
    local csm_bin="${CSM_ROOT_DIR}/csm.sh"
    if [[ ! -e "$bin_link" && ! -L "$bin_link" ]]; then
        $var_sudo ln -sf "$csm_bin" "$bin_link"
        _log INFO "Created symlink: $bin_link → $csm_bin"
    elif [[ -L "$bin_link" ]]; then
        _log PASS "Symlink $bin_link already exists."
    else
        _log WARN "$bin_link exists and is not a symlink – leaving it alone."
    fi
}

# =============================================================================
# 10. OWNERSHIP
# =============================================================================

_set_ownership() {
    _log STEP "Setting group on ${CSM_ROOT_DIR} to ${csm_group}..."
    [ "$(_get_group "$CSM_ROOT_DIR")" != "$csm_group" ] && $var_sudo chgrp "$csm_group" "$CSM_ROOT_DIR"
    [ "$(_get_perms "$CSM_ROOT_DIR" | cut -c6)" != "s" ] && $var_sudo chmod g+s "$CSM_ROOT_DIR"
}

# =============================================================================
# 11. MAIN
# =============================================================================

main() {
    _log STEP "CSM Installer v${INSTALLER_VERSION} – starting"
    _log INFO "Install root: ${CSM_ROOT_DIR}"
    _log INFO "Invoking user: ${csm_owner} (UID ${csm_uid})"

    _detect_pkg_manager
    _install_container_runtime
    [[ "$_runtime" == "podman" ]] && csm_group="podman"
    _check_container_service
    _create_runtime_group
    _setup_directories
    _setup_files
    _setup_symlinks
    _set_ownership

    echo ""
    _log PASS "CSM installation complete!"
    _log INFO "Next steps:"
    _log INFO "  1. Edit user config : ${csm_configs}/user.conf"
    _log INFO "  2. View your stacks : ${csm_stacks}/"
    _log INFO "  3. Get started      : csm --help"
    [[ "$_runtime" == "docker" ]] && [[ "$(groups)" != *docker* ]] && \
        _log WARN "Remember to log out and back in so your docker group membership takes effect."
}

main "$@"
