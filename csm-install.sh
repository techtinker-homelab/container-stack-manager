#!/usr/bin/env bash
# =============================================================================
# csm-install.sh  –  Container Stack Manager Installer
# =============================================================================

set -euo pipefail

# .lock file created to prevent duplicate installer scripts running concurrently
LOCKFILE="/var/lock/csm-install.lock"
if ! command -v flock >/dev/null 2>&1; then
    echo "WARNING: flock not found – install util-linux or coreutils for safety." >&2
    exit 1
fi
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "Another instance of csm-install.sh is already running." >&2
    exit 1
fi

# Prevent sourcing — must be executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    : # running directly, proceed
else
    echo "ERROR: This script must be executed directly, not sourced." >&2
    echo "Run: bash csm-install.sh  (or ./csm-install.sh)" >&2
    return 1 2>/dev/null || exit 1
fi

# =============================================================================

# What this script does (in order):
#   1.  Validate root / sudo access
#   2.  Detect OS package manager
#   3.  Detect or install container runtime (Docker or Podman)
#   4.  Check / start the container service
#   5.  Check / create the docker user + group (UID/GID 2000, Docker only)
#   6.  Create the CSM directory structure with correct permissions
#   7.  Install core CSM files
#   8.  Create ~/stacks symlink pointing to CSM_DIR
#   9.  Symlink /usr/local/bin/csm → CSM_DIR/.configs/csm.sh
#  10.  Set final ownership

readonly INSTALLER_VERSION="0.3.1"

force_install=0
uninstall_mode=0

csm_runtime=""   # set by _detect_container_runtime or _install_container_runtime

# =============================================================================
# 0. HELPER FUNCTIONS
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
    case "$level" in
        EXIT|FAIL)  color="${red}" ;;
        INFO)       color="${cyn}" ;;
        PASS)       color="${grn}" ;;
        STEP)       color="${mgn}"; if [[ "${csm_debug:-0}" == "0" ]]; then return 0; fi ;;
        WARN)       color="${ylw}" ;;
        *)          color="${ylw}"; level="WARN"
                    message="[Unknown log type: '${level}'] $message"
                    ;;
    esac
    printf "%s %-4s >> %s%s\n" "${color}${bld}" "${level}" "${message}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_die() { _log FAIL "$1"; exit 1; }

_confirm_yes() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    if [[ -z "${reply}" || "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1 so the script doesn't crash
}

_confirm_no() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" reply
    if [[ "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1
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

export csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
export csm_backups="${CSM_BACKUPS_DIR:-${csm_dir}/.backups}"
export csm_configs="${CSM_CONFIGS_DIR:-${csm_dir}/.configs}"
export csm_modules="${CSM_MODULES_DIR:-${csm_dir}/.modules}"
export csm_secrets="${CSM_SECRETS_DIR:-${csm_dir}/.secrets}"

# Owner — when run via sudo, use the invoking user; else current user
csm_owner="${SUDO_USER:-$(id -un)}"
csm_group="docker"   # default, overridden after runtime detection
csm_uid="${SUDO_UID:-$(id -u)}"
csm_gid=2000         # default, overridden by _create_runtime_group

readonly csm_link="${HOME}/stacks"
readonly bin_link="/usr/local/bin/csm"

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_dir="775"  # directories:  rwxrwxr-x
readonly mode_exec="770" # executables:  rwxrwx---
readonly mode_conf="660" # config files: rw-rw----
readonly mode_auth="600" # secret files: rw-------

# Files to install: source → destination directory
declare -A files_to_install=(
    ["${script_dir}/csm.sh"]="${csm_configs}/"
)
# example.conf → default.conf (only if default.conf doesn't already exist)
if [[ -f "${script_dir}/example.conf" ]]; then
    files_to_install["${script_dir}/example.conf"]="${csm_configs}/"
fi
if [[ -f "${script_dir}/example.env" ]]; then
    files_to_install["${script_dir}/example.env"]="${csm_configs}/"
fi

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
    _log STEP "_detect_pkg_manager: detected=$pkg_mgr"
}

_install_pkg() {
    if [[ -z "${pkg_mgr:-}" ]]; then _log WARN "No pkg manager – skipping: $*"; return 0; fi
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
        csm_runtime="docker"
        _log STEP "_detect_container_runtime: docker detected"
        return 0
    elif command -v podman >/dev/null 2>&1; then
        _log PASS "Podman found: $(podman --version)"
        csm_runtime="podman"
        csm_group="podman"
        _log STEP "_detect_container_runtime: podman detected"
        return 0
    fi
    _log STEP "_detect_container_runtime: no runtime found"
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
}

_install_podman() {
    _log STEP "_install_podman: installing via package manager..."
    _install_pkg podman
    _log PASS "Podman installed: $(podman --version)"
    csm_runtime="podman"
}

_install_container_runtime() {
    _log STEP "_install_container_runtime: checking for existing runtime..."
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
    _log STEP "_install_container_runtime: user choice=$choice"
    case "$choice" in
        1|docker) _install_docker ;;
        2|podman) _install_podman ;;
        "")       _install_docker ;;
        *)        _die "Invalid choice. Aborting." ;;
    esac
    if [[ "$csm_runtime" == "docker" ]]; then
        _configure_swarm
    fi
}

_configure_swarm() {
    _log STEP "_configure_swarm: configuring Docker deployment mode..."

    _log INFO "Choose your Docker deployment mode:"
    _log INFO "  1) Local Compose (Standard)"
    _log INFO "  2) Docker Swarm (Orchestration)"
    local choice=""
    read -r -p "${ylw}${bld} Select [1/2] (default 1): ${rst}" choice

    case "$choice" in
        2|swarm)
            _log STEP "_configure_swarm: Swarm mode selected."

            # Check if already in a swarm
            if $var_sudo docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
                _log PASS "Docker is already active in Swarm mode."
                return 0
            fi

            _log INFO "Docker is not currently in Swarm mode."
            if _confirm_yes "Join an existing Swarm cluster?"; then
                local token ip
                read -r -p "Enter Swarm Join Token: " token
                read -r -p "Enter Manager IP (e.g., 192.168.1.10): " ip

                if [[ -n "$token" && -n "$ip" ]]; then
                    _log STEP "_configure_swarm: joining swarm at $ip..."
                    $var_sudo docker swarm join --token "$token" "$ip:2377" \
                        && _log PASS "Successfully joined the Swarm cluster." \
                        || _log FAIL "Failed to join the Swarm cluster."
                else
                    _log WARN "Token or IP missing. Skipping join process."
                fi
            elif _confirm_yes "Initialize this node as a Swarm Manager?"; then
                _log STEP "_configure_swarm: initializing swarm..."
                $var_sudo docker swarm init \
                    && _log PASS "Swarm initialized. This node is now a Manager." \
                    || _log FAIL "Failed to initialize Swarm."
            else
                _log INFO "No Swarm action taken. Node remains in Local mode."
            fi
            ;;
        *)
            _log INFO "Local Compose mode selected (default)."
            ;;
    esac
}

# =============================================================================
# 6. CONTAINER SERVICE CHECK
# =============================================================================

_check_container_service() {
    _log STEP "_check_container_service: runtime=$csm_runtime"
    case "$csm_runtime" in
        docker)
            _log STEP "Checking Docker service..."
            if ! command -v systemctl >/dev/null 2>&1; then
                _log WARN "systemctl not found – skipping service check."
                return 0
            fi
            _log STEP "_check_container_service: checking systemctl is-active docker"
            if systemctl is-active --quiet docker; then
                _log PASS "Docker service is running."
                return 0
            fi
            _log WARN "Docker service is not running."
            _confirm_yes "Start Docker now?" && {
                _log STEP "_check_container_service: running systemctl start docker"
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
            _log STEP "_check_container_service: checking systemctl is-active podman.socket"
            if systemctl is-active --quiet podman.socket 2>/dev/null; then
                _log PASS "Podman socket is active."
                return 0
            fi
            _log WARN "Podman socket is not active (optional for rootless)."
            _confirm_yes "Enable Podman socket?" && {
                _log STEP "_check_container_service: running systemctl enable --now podman.socket"
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
    local lgid=${csm_gid:-2000}
    _log STEP "_create_runtime_group: checking if group '$csm_group' (GID $lgid) exists..."

    if ! getent group "$csm_group" >/dev/null 2>&1; then
        _log STEP "_create_runtime_group: creating group..."
        $var_sudo groupadd -g "$lgid" "$csm_group" \
            && _log INFO "Created group '$csm_group' (GID $lgid)" \
            || _die "Failed to create group '$csm_group'"
    else
        _log INFO "Group '$csm_group' (GID $lgid) already exists."
    fi

    # Use the actual GID (may differ if group already existed with different GID)
    csm_gid="$(getent group "$csm_group" | cut -d: -f3)"
    _log STEP "_create_runtime_group: resolved csm_gid=$csm_gid"

    local current_user="${SUDO_USER:-$(id -un)}"
    _log STEP "_create_runtime_group: checking if user '$current_user' is in group '$csm_group'..."
    if ! groups "$current_user" 2>/dev/null | grep -qw "$csm_group"; then
        _log WARN "User '$current_user' is not in the '$csm_group' group."
        _confirm_yes "Add '$current_user' to '$csm_group'?" && {
            _log STEP "_create_runtime_group: running gpasswd -a $current_user $csm_group"
            $var_sudo gpasswd -a "$current_user" "$csm_group"
            _log INFO "User added. Log out and back in for this to take effect."
        }
    else
        _log PASS "User '$current_user' is in the '$csm_group' group."
    fi
}

# =============================================================================
# 8. CONTAINER DIRECTORIES AND NETWORKING
# =============================================================================

_install_dir() {
    local tgt="$1" mode="$2"
    if [[ ! -d "$tgt" ]]; then
        _log STEP "_install_dir: creating $tgt (mode=$mode)"
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -d "$tgt"
        _log INFO "Created: $tgt"
    fi
}

_install_file() {
    local src="$1" dest_dir="$2" mode="$3" flag="$4"
    local filename=$(basename "$src")

    if [[ -f "$src" ]]; then
        _log STEP "_install_file: installing $filename (mode=$mode)"
        case "$flag" in
            -f | --force)
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -p "$src" "$dest_dir/"
                ;;
            *)
                # -v: verbose, -C: only copy if different, -p: preserve timestamps
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -C -p "$src" "$dest_dir/"
        esac
        _log INFO "Installed: $filename → $dest_dir"
    else
        _log WARN "Source file missing: $src"
    fi
}

_setup_directories() {
    # Ensure /srv is writable or exists before trying to create /srv/stacks
    if [[ ! -w "/srv" ]] && [[ ! -d "$csm_dir" ]]; then
        _log ERROR "Cannot write to /srv. Are you running with sufficient privileges?"
        return 1
    fi
    _log STEP "_setup_directories: initializing structure at ${csm_dir}"
    local target_dirs=(
        "$csm_dir"
        "$csm_backups"
        "$csm_configs"
        "$csm_modules"
        "$csm_secrets"
    )
    for dir in "${target_dirs[@]}"; do
        _install_dir "$dir" "$mode_dir"
    done
    _log INFO "_setup_directories: done"
}

_setup_files() {
    _log STEP "_setup_files: installing CSM core files..."

    local conf_example="${script_dir}/example.conf"
    local conf_default="${csm_configs}/default.conf"
    local conf_user="${csm_configs}/user.conf"

    local compose_example="${script_dir}/example-compose.yml"
    local compose_local="${csm_configs}/local-compose.yml"
    local compose_swarm="${csm_configs}/swarm-compose.yml"

    local env_example="${script_dir}/example.env"
    local env_local="${csm_configs}/.local.env"
    local env_swarm="${csm_configs}/.swarm.env"

    # 1. Install the core script
    _install_file "${script_dir}/csm.sh" "${csm_configs}/" "$mode_exec" --force

    # 2. Handle Env Templates
    if [[ -f "$env_example" ]]; then
        _install_file "$env_example" "${csm_configs}/" "$mode_conf"
        if [[ ! -f "$env_local" || "$force_install" == 1 ]]; then
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$env_example" "$env_local"
        fi
        if [[ ! -f "$env_swarm" || "$force_install" == 1 ]]; then
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$env_example" "$env_swarm"
        fi
        _log INFO "Initial setup: Created/Overwrote local and swarm .env templates"
    fi

    # 3. Handle Compose Templates
    if [[ -f "$compose_example" ]]; then
        _install_file "$compose_example" "${csm_configs}/" "$mode_conf"
        if [[ ! -f "$compose_local" || "$force_install" == 1 ]]; then
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$compose_example" "$compose_local"
        fi
        if [[ ! -f "$compose_swarm" || "$force_install" == 1 ]]; then
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$compose_example" "$compose_swarm"
        fi
        _log INFO "Initial setup: Created/Overwrote local and swarm compose templates"
    fi

    # 4. Handle Core Configurations
    if [[ -f "$conf_example" ]]; then
        _install_file "$conf_example" "${csm_configs}/" "$mode_conf" --force
        if [[ ! -f "$conf_default" || "$force_install" == 1 ]]; then
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$conf_example" "$conf_default"
            _log INFO "Initial setup: Created/Overwrote $conf_default"
        fi
    fi
    if [[ -f "$conf_default" ]] && [[ ! -f "$conf_user" || "$force_install" == 1 ]]; then
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$conf_default" "$conf_user"
        _log INFO "Initial setup: Created/Overwrote $conf_user"
    fi

    # 5. Consolidated Patching Logic
    local targets=()
    if [[ -f "$conf_default" ]]; then targets+=("$conf_default"); fi
    if [[ -f "$conf_user" ]]; then targets+=("$conf_user"); fi
    if [[ ${#targets[@]} -gt 0 ]]; then
        _log STEP "_setup_files: patching runtime variables..."
        sed -i  -e "s|^CSM_CONTAINER_RUNTIME=.*|CSM_CONTAINER_RUNTIME=${csm_runtime}|" \
                -e "s|^CSM_ROOT_DIR=.*|CSM_ROOT_DIR=\"${csm_dir}\"|" \
                -e "s|^CSM_STACKS_GID=.*|CSM_STACKS_GID=${csm_gid}|" \
                -e "s|^CSM_STACKS_UID=.*|CSM_STACKS_UID=${csm_uid}|" \
                "${targets[@]}"
    fi

    _log INFO "_setup_files: done"
}

_setup_network() {
    local net_name="${CSM_NETWORK_NAME:-csm_network}"
    _log STEP "_setup_network: ensuring network '$net_name' exists..."

    # Determine binary based on detected runtime
    local cmd="$csm_runtime"
    if [[ -z "$cmd" ]]; then
        _log WARN "No container runtime detected. Skipping network setup."
        return 1
    fi

    # Check if the network already exists
    if $var_sudo "$cmd" network inspect "$net_name" >/dev/null 2>&1; then
        _log INFO "Network '$net_name' already exists."
        return 0
    fi

    case "$csm_runtime" in
        podman)
            _log STEP "_setup_network: creating podman network $net_name"
            $var_sudo podman network create "$net_name" \
                && _log PASS "Podman network '$net_name' created." \
                || _log WARN "Failed to create Podman network '$net_name'."
            ;;
        docker)
            # Check if Swarm is active to determine network driver
            if $var_sudo docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
                _log STEP "_setup_network: creating docker swarm overlay network $net_name"
                $var_sudo docker network create --driver overlay --attachable "$net_name" \
                    && _log PASS "Docker Swarm network '$net_name' created." \
                    || _log WARN "Failed to create Docker Swarm network '$net_name'."
            else
                _log STEP "_setup_network: creating docker bridge network $net_name"
                $var_sudo docker network create "$net_name" \
                    && _log PASS "Docker network '$net_name' created." \
                    || _log WARN "Failed to create Docker network '$net_name'."
            fi
            ;;
        *)
            _log WARN "Unsupported runtime '$csm_runtime' for network setup."
            ;;
    esac
}

# =============================================================================
# 9. SYMLINKS
# =============================================================================

_setup_symlinks() {
    _log STEP "_setup_symlinks: setting up symlinks..."

    # 1. Convenience Link: ~/stacks -> CSM_ROOT_DIR
    local link_source="$csm_link"
    local link_target="$csm_dir"

    if [[ -L "$link_source" ]]; then
        # Use -f to resolve absolute paths for comparison
        if [[ "$(readlink -f "$link_source")" != "$(readlink -f "$link_target")" ]]; then
            _log WARN "Symlink $link_source is misaligned. Correcting..."
            rm -f "$link_source"
            ln -s "$link_target" "$link_source"
        fi
    elif [[ ! -e "$link_source" ]]; then
        ln -s "$link_target" "$link_source"
        _log INFO "Created symlink: $link_source"
    fi

    # 2. Binary Link: /usr/local/bin/csm -> .configs/csm.sh
    local bin_source="$bin_link"
    local bin_target="${csm_configs}/csm.sh"

    if [[ -L "$bin_source" ]]; then
        if [[ "$(readlink -f "$bin_source")" != "$(readlink -f "$bin_target")" ]]; then
            _log WARN "Binary link $bin_source is misaligned. Correcting..."
            $var_sudo ln -sf "$bin_target" "$bin_source"
        fi
    elif [[ ! -e "$bin_source" ]]; then
        $var_sudo ln -sf "$bin_target" "$bin_source"
        _log INFO "Created binary symlink: $bin_source"
    fi
}

_set_ownership() {
    _log STEP "_set_ownership: setting group on ${csm_dir} to ${csm_group}..."
    local current_group
    current_group="$(_get_group "$csm_dir")"
    _log STEP "_set_ownership: current group=$current_group, target=$csm_group"
    [ "$current_group" != "$csm_group" ] && {
        _log STEP "_set_ownership: running chgrp $csm_group $csm_dir"
        $var_sudo chgrp "$csm_group" "$csm_dir"
    }
    local current_perms
    current_perms="$(_get_perms "$csm_dir")"
    local sgid_bit
    sgid_bit="$(echo "$current_perms" | cut -c6)"
    _log STEP "_set_ownership: current perms=$current_perms, sgid bit=$sgid_bit"
    [ "$sgid_bit" != "s" ] && {
        _log STEP "_set_ownership: running chmod g+s $csm_dir"
        $var_sudo chmod g+s "$csm_dir"
    }
    _log INFO "_set_ownership: done"
}

# =============================================================================
# 11. UNINSTALL
# =============================================================================

_uninstall_csm() {
    _log WARN "Starting CSM uninstallation..."
    _log INFO "This will remove the core engine and symlinks."
    _log INFO "Your stacks, user.conf, and templates will NOT be modified."

    _confirm_yes "Proceed with uninstallation?" || { _log INFO "Cancelled."; exit 0; }

    # 1. Remove Symlinks
    if [[ -L "$bin_link" ]]; then
        _log STEP "Removing binary symlink: $bin_link"
        $var_sudo rm -f "$bin_link"
    fi
    if [[ -L "$csm_link" ]]; then
        _log STEP "Removing home directory symlink: $csm_link"
        rm -f "$csm_link"
    fi

    # 2. Remove Core Engine Files
    if [[ -f "${csm_configs}/csm.sh" ]]; then
        _log STEP "Removing core script: ${csm_configs}/csm.sh"
        $var_sudo rm -f "${csm_configs}/csm.sh"
    fi
    if [[ -f "${csm_configs}/default.conf" ]]; then
        _log STEP "Removing default config: ${csm_configs}/default.conf"
        $var_sudo rm -f "${csm_configs}/default.conf"
    fi

    _log PASS "CSM core files and symlinks have been removed."
    _log INFO "Note: The container runtime, groups, and ${csm_dir} directories remain intact."
    exit 0
}

# =============================================================================
# 12. HELP
# =============================================================================

show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) Installer v${INSTALLER_VERSION}${rst}

${bld}Usage:${rst} ${script_dir}/csm-install.sh [options]

${bld}Options:${rst}
    -f | --force        over-writes script and config files without confirmation.
    -h | --help         Show this help message.
    -u | --uninstall    Uninstall all CSM scripts and unmodified config files.
    -V | --version      Show installer version.

${bld}Container Stack Manager Installer (csm-install.sh) version:${rst} ${ylw}${INSTALLER_VERSION}${rst}
EOF
}

# =============================================================================
# 13. MAIN
# =============================================================================

main() {
    _color_setup
    # if [[ -z "${1:-}" ]]; then show_help; exit 0; fi
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            # -d | --dryrun)      dry_run=1; csm_debug=1; shift ;; # TODO: implement dry run feature
            -f | --force)       force_install=1; shift ;;
            -h | --help )       show_help; exit 0 ;;
            # -i | --install)     : ;;
            -u | --uninstall)   uninstall_mode=1; shift ;;
            -V | --version)     _log PASS "Container Stack Manager Installer, csm-install.sh version: ${INSTALLER_VERSION}"; exit 0 ;;
            *) _log WARN "Unknown argument: $1 \n Use './csm-install.sh help' to view supported options."; shift ;;
        esac
    done

    # Handle uninstallation
    if [[ "$uninstall_mode" == 1 ]]; then
        _uninstall_csm
    fi
    _log INFO "CSM Installer v${INSTALLER_VERSION} – starting"
    if [[ "$force_install" == 1 ]]; then
        _log WARN "FORCE MODE ACTIVE: Existing configs will be overwritten and prompts bypassed."
    fi

    _log INFO "Install root: ${csm_dir}"
    _log INFO "Invoking user: ${csm_owner} (UID ${csm_uid})"

    _log STEP "main: detecting package manager..."
    _detect_pkg_manager
    _log STEP "main: detecting/installing container runtime..."
    _install_container_runtime
    _log STEP "main: checking container service..."
    _check_container_service
    _log STEP "main: creating runtime group..."
    _create_runtime_group
    _log STEP "main: setting up network..."
    _setup_network
    _log STEP "main: setting up directories..."
    _setup_directories
    _log STEP "main: installing files..."
    _setup_files
    _log STEP "main: setting up symlinks..."
    _setup_symlinks
    _log STEP "main: setting ownership..."
    _set_ownership

    echo ""
    _log PASS "CSM installation complete!"
    _log INFO "Next steps:"
    _log INFO "  1. Edit user config : ${csm_configs}/user.conf"
    _log INFO "  2. View your stacks : ${csm_dir}/"
    _log INFO "  3. Get started      : csm --help"
    if [[ "$csm_runtime" == "docker" && "$(groups)" != *docker* ]]; then
        _log WARN "Remember to log out and back in so your docker group membership takes effect."
    fi
}

main "$@"
