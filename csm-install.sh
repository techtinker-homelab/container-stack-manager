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
        mgn=$(_tput_safe setaf 5)
        cyn=$(_tput_safe setaf 6)
        wht=$(_tput_safe setaf 7)
        blk=$(_tput_safe setaf 0)
        bld=$(_tput_safe bold)
        uln=$(_tput_safe smul)
        rst=$(_tput_safe sgr0)
    else
        red="" grn="" ylw="" blu="" mgn="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    fi
}
_color_setup

_log() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        EXIT) printf "%s EXIT >> %s%s\n" "${red}${bld}" "${message}" "${rst}" >&2; exit 1 ;;
        FAIL) printf "%s FAIL >> %s%s\n" "${red}${bld}" "${message}" "${rst}" >&2 ;;
        INFO) printf "%s INFO >> %s%s\n" "${cyn}${bld}" "${message}" "${rst}" ;;
        PASS) printf "%s PASS >> %s%s\n" "${grn}${bld}" "${message}" "${rst}" ;;
        STEP) [[ "${CSM_DEBUG:-1}" == "1" ]] && printf "%s STEP >> %s%s\n" "${mgn}${bld}" "${message}" "${rst}" ;;
        WARN) printf "%s WARN >> %s%s\n" "${ylw}${bld}" "${message}" "${rst}" >&2 ;;
        *)    printf "%s WARN >> _log: unknown level '%s'%s\n" "${ylw}${bld}" "${level}" "${rst}" >&2 ;;
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
    _log STEP "_detect_pkg_manager: detected=$pkg_mgr"
}

_install_pkg() {
    [[ -z "${pkg_mgr:-}" ]] && { _log WARN "No pkg manager – skipping: $*"; return 0; }
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
        _runtime="docker"
        _log STEP "_detect_container_runtime: docker detected"
        return 0
    elif command -v podman >/dev/null 2>&1; then
        _log PASS "Podman found: $(podman --version)"
        _runtime="podman"
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
    _runtime="docker"
}

_install_podman() {
    _log STEP "_install_podman: installing via package manager..."
    _install_pkg podman
    _log PASS "Podman installed: $(podman --version)"
    _runtime="podman"
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
}

# =============================================================================
# 6. CONTAINER SERVICE CHECK
# =============================================================================

_check_container_service() {
    _log STEP "_check_container_service: runtime=$_runtime"
    case "$_runtime" in
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
    local gid=2000
    _log STEP "_create_runtime_group: checking if group '$csm_group' (GID $gid) exists..."

    if ! getent group "$gid" >/dev/null 2>&1; then
        _log STEP "_create_runtime_group: creating group..."
        $var_sudo groupadd -g "$gid" "$csm_group" \
            && _log INFO "Created group '$csm_group' (GID $gid)" \
            || _die "Failed to create group '$csm_group'"
    else
        _log INFO "Group '$csm_group' (GID $gid) already exists."
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
# 8. DIRECTORY STRUCTURE
# =============================================================================

_install_dir() {
    local tgt="$1" mode="$2"
    if [[ ! -d "$tgt" ]]; then
        _log STEP "_install_dir: creating $tgt (mode=$mode)"
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -d "$tgt"
        _log INFO "Created: $tgt"
    else
        _log INFO "Exists:  $tgt"
    fi
}

_install_file() {
    local src="$1" dest_dir="$2" mode="$3"
    if [[ -f "$src" ]]; then
        _log STEP "_install_file: installing $(basename "$src") → $dest_dir (mode=$mode)"
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" "$src" "$dest_dir/"
        _log INFO "Installed: $(basename "$src") → $dest_dir"
    else
        _log WARN "Source file missing – skipping: $src"
    fi
}

_setup_directories() {
    _log STEP "_setup_directories: creating structure under ${CSM_ROOT_DIR}..."
    _install_dir "$CSM_ROOT_DIR" "$mode_dir"
    _install_dir "$csm_backup"   "$mode_dir"
    _install_dir "$csm_common"   "$mode_dir"
    _install_dir "$csm_stacks"   "$mode_dir"
    _install_dir "$csm_configs"  "$mode_dir"
    _install_dir "$csm_secrets"  "$mode_dir"
    _log STEP "_setup_directories: done"
}

_setup_files() {
    _log STEP "_setup_files: installing CSM core files..."
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
        _log STEP "_setup_files: renaming example.conf → default.conf"
        $var_sudo mv "$example_conf" "$default_conf"
        _log INFO "Renamed example.conf → default.conf"
    fi

    # Patch detected runtime values into default.conf
    if [[ -f "$default_conf" ]]; then
        _log STEP "_setup_files: patching CSM_CONTAINER_RUNTIME=${_runtime} and CSM_STACKS_GID=${csm_gid} into default.conf"
        sed -i "s/^CSM_CONTAINER_RUNTIME=.*/CSM_CONTAINER_RUNTIME=${_runtime}/" "$default_conf"
        sed -i "s/^CSM_STACKS_GID=.*/CSM_STACKS_GID=${csm_gid}/" "$default_conf"
        _log INFO "Patched CSM_CONTAINER_RUNTIME=${_runtime} and CSM_STACKS_GID=${csm_gid} into default.conf"
    fi
    _log STEP "_setup_files: done"
}

# =============================================================================
# 9. SYMLINKS
# =============================================================================

_setup_symlinks() {
    _log STEP "_setup_symlinks: setting up symlinks..."

    # ~/stacks  → CSM_ROOT_DIR
    local target_dir="$CSM_ROOT_DIR"
    _log STEP "_setup_symlinks: checking ~/stacks symlink ($link_path → $target_dir)"
    if [[ ! -e "$link_path" && ! -L "$link_path" ]]; then
        _log STEP "_setup_symlinks: creating symlink $link_path → $target_dir"
        ln -s "$target_dir" "$link_path"
        _log INFO "Created symlink: $link_path → $target_dir"
    elif [[ -L "$link_path" ]]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if [[ "$current_target" != "$target_dir" ]]; then
            _log WARN "Symlink $link_path points to $current_target (expected $target_dir)"
            _confirm_no "Update symlink to point to $target_dir?" && {
                _log STEP "_setup_symlinks: updating symlink $link_path"
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
    _log STEP "_setup_symlinks: checking $bin_link → $csm_bin"
    if [[ ! -e "$bin_link" && ! -L "$bin_link" ]]; then
        _log STEP "_setup_symlinks: creating symlink $bin_link → $csm_bin"
        $var_sudo ln -sf "$csm_bin" "$bin_link"
        _log INFO "Created symlink: $bin_link → $csm_bin"
    elif [[ -L "$bin_link" ]]; then
        _log PASS "Symlink $bin_link already exists."
    else
        _log WARN "$bin_link exists and is not a symlink – leaving it alone."
    fi
    _log STEP "_setup_symlinks: done"
}

_set_ownership() {
    _log STEP "_set_ownership: setting group on ${CSM_ROOT_DIR} to ${csm_group}..."
    local current_group
    current_group="$(_get_group "$CSM_ROOT_DIR")"
    _log STEP "_set_ownership: current group=$current_group, target=$csm_group"
    [ "$current_group" != "$csm_group" ] && {
        _log STEP "_set_ownership: running chgrp $csm_group $CSM_ROOT_DIR"
        $var_sudo chgrp "$csm_group" "$CSM_ROOT_DIR"
    }
    local current_perms
    current_perms="$(_get_perms "$CSM_ROOT_DIR")"
    local sgid_bit
    sgid_bit="$(echo "$current_perms" | cut -c6)"
    _log STEP "_set_ownership: current perms=$current_perms, sgid bit=$sgid_bit"
    [ "$sgid_bit" != "s" ] && {
        _log STEP "_set_ownership: running chmod g+s $CSM_ROOT_DIR"
        $var_sudo chmod g+s "$CSM_ROOT_DIR"
    }
    _log STEP "_set_ownership: done"
}

# =============================================================================
# 11. MAIN
# =============================================================================

main() {
    _log STEP "CSM Installer v${INSTALLER_VERSION} – starting"
    _log STEP "main: CSM_ROOT_DIR=$CSM_ROOT_DIR, csm_owner=$csm_owner, csm_uid=$csm_uid"
    _log INFO "Install root: ${CSM_ROOT_DIR}"
    _log INFO "Invoking user: ${csm_owner} (UID ${csm_uid})"

    _log STEP "main: detecting package manager..."
    _detect_pkg_manager
    _log STEP "main: detecting/installing container runtime..."
    _install_container_runtime
    _log STEP "main: runtime=$_runtime"
    [[ "$_runtime" == "podman" ]] && csm_group="podman"
    _log STEP "main: checking container service..."
    _check_container_service
    _log STEP "main: creating runtime group..."
    _create_runtime_group
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
    _log INFO "  2. View your stacks : ${csm_stacks}/"
    _log INFO "  3. Get started      : csm --help"
    [[ "$_runtime" == "docker" ]] && [[ "$(groups)" != *docker* ]] && \
        _log WARN "Remember to log out and back in so your docker group membership takes effect."
}

main "$@"
