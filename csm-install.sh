#!/usr/bin/env bash
# =============================================================================
# csm-install.sh  –  Container Stack Manager Installer
# =============================================================================
# What this script does (in order):
#   1.  Validate root / sudo access
#   2.  Detect OS package manager
#   3.  Check / start the Docker service
#   4.  Check / create the docker user + group (UID/GID 2000)
#   5.  Install Docker if missing
#   6.  Create the CSM directory structure with correct permissions
#   7.  Install core CSM files
#   8.  Create ~/stacks symlink pointing to CSM_ROOT_DIR
#   9.  Symlink /usr/local/bin/csm → CSM_ROOT_DIR/csm.sh
#  10.  Set final ownership
# =============================================================================

set -euo pipefail

readonly INSTALLER_VERSION="1.1.0"

# =============================================================================
# 0. HELPERS
# =============================================================================

tput_safe() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

color_setup() {
    if [[ -t 1 ]]; then
        red=$(tput_safe setaf 1)
        grn=$(tput_safe setaf 2)
        ylw=$(tput_safe setaf 3)
        blu=$(tput_safe setaf 4)
        prp=$(tput_safe setaf 5)
        cyn=$(tput_safe setaf 6)
        wht=$(tput_safe setaf 7)
        blk=$(tput_safe setaf 0)
        bld=$(tput_safe bold)
        uln=$(tput_safe smul)
        rst=$(tput_safe sgr0)
    else
        red="" grn="" ylw="" blu="" prp="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    fi
}
color_setup

log() {
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

die()     { log FAIL "$1"; exit 1; }

confirm_yes() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    [[ -z "${reply}" || "${reply,,}" == "y" ]]
}

confirm_no() {
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
    die "This installer requires root or sudo. Neither is available."
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
csm_group="docker"                 # adjust if not using the docker group
csm_uid="${SUDO_UID:-$(id -u)}"
csm_gid="${SUDO_GID:-$(id -g)}"

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
    ["${script_dir}/default.conf"]="${csm_configs}/"
)
# example.env is optional
[[ -f "${script_dir}/example.env" ]] && \
    files_to_install["${script_dir}/example.env"]="${csm_common}/"

# =============================================================================
# 4. PLATFORM DETECTION
# =============================================================================

detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then pkg_mgr="apt-get"
    elif command -v dnf     >/dev/null 2>&1; then pkg_mgr="dnf"
    elif command -v yum     >/dev/null 2>&1; then pkg_mgr="yum"
    elif command -v pacman  >/dev/null 2>&1; then pkg_mgr="pacman"
    else
        log WARN "Unsupported package manager – install curl, git manually if needed."
        pkg_mgr=""
    fi
}

install_pkg() {
    [[ -z "${pkg_mgr:-}" ]] && { log WARN "No pkg manager – skipping: $*"; return 0; }
    case "$pkg_mgr" in
        apt-get) $var_sudo apt-get install -y "$@" ;;
        dnf|yum) $var_sudo "$pkg_mgr" install -y "$@" ;;
        pacman)  $var_sudo pacman -S --noconfirm "$@" ;;
    esac
}

get_group() {
    local file="$1"
    stat -c '%G' "$file" 2>/dev/null || stat -f '%Sg' "$file"
}

get_perms() {
    local file="$1"
    stat -c '%A' "$file" 2>/dev/null || stat -f '%Sp' "$file"
}

# =============================================================================
# 5. DOCKER SERVICE CHECK
# =============================================================================

check_docker_service() {
    log STEP "Checking Docker service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log WARN "systemctl not found – skipping service check."
        return 0
    fi
    if systemctl is-active --quiet docker; then
        log PASS "Docker service is running."
        return 0
    fi
    log WARN "Docker service is not running."
    confirm_yes "Start Docker now?" && {
        $var_sudo systemctl start docker
        systemctl is-active --quiet docker \
            && log PASS "Docker started." \
            || die "Failed to start Docker. Check: journalctl -u docker"
    }
}

# =============================================================================
# 6. DOCKER USER / GROUP  (UID/GID 2000)
# =============================================================================

create_docker_user_group() {
    log STEP "Checking docker user/group (UID/GID 2000)..."
    local uid=2000 gid=2000

    if ! getent group "$gid" >/dev/null 2>&1; then
        $var_sudo groupadd -g "$gid" docker \
            && log INFO "Created group 'docker' (GID $gid)" \
            || die "Failed to create group 'docker'"
    else
        log INFO "Group 'docker' (GID $gid) already exists."
    fi

    if ! getent passwd "$uid" >/dev/null 2>&1; then
        $var_sudo useradd -m -u "$uid" -g docker -s /usr/sbin/nologin docker \
            && log INFO "Created user 'docker' (UID $uid)" \
            || die "Failed to create user 'docker'"
    else
        log INFO "User 'docker' (UID $uid) already exists."
    fi

    # Ensure the invoking user is also in the docker group
    local current_user="${SUDO_USER:-$(id -un)}"
    if ! groups "$current_user" 2>/dev/null | grep -qw docker; then
        log WARN "User '$current_user' is not in the 'docker' group."
        confirm_yes "Add '$current_user' to the 'docker' group?" && {
            $var_sudo gpasswd -a "$current_user" "$csm_group"
            log INFO "User added. Log out and back in for this to take effect."
        }
    else
        log PASS "User '$current_user' is in the 'docker' group."
    fi
}

# =============================================================================
# 7. DOCKER INSTALLATION
# =============================================================================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log INFO "Docker already installed: $(docker --version)"
        return 0
    fi
    log INFO "Docker not found – installing via get.docker.com..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh \
        || die "Failed to download Docker installer."
    $var_sudo sh /tmp/get-docker.sh \
        || die "Docker installation failed."
    rm -f /tmp/get-docker.sh
    log PASS "Docker installed: $(docker --version)"
}

# =============================================================================
# 8. DIRECTORY STRUCTURE
# =============================================================================

# install_dir <path> <mode>
install_dir() {
    local tgt="$1" mode="$2"
    if [[ ! -d "$tgt" ]]; then
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -d "$tgt"
        log INFO "Created: $tgt"
    else
        log INFO "Exists:  $tgt"
    fi
}

# install_file <src> <dest_dir> <mode>
install_file() {
    local src="$1" dest_dir="$2" mode="$3"
    if [[ -f "$src" ]]; then
        # run_cmd install -o "$csm_uid" -g "$csm_gid" -m "$mode" /dev/null "$stacks_dir${scope}/${stack}/compose.yml"
        $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" "$src" "$dest_dir/"
        log INFO "Installed: $(basename "$src") → $dest_dir"
    else
        log WARN "Source file missing – skipping: $src"
    fi
}

setup_directories() {
    log STEP "Creating CSM directory structure under ${CSM_ROOT_DIR}..."
    install_dir "$CSM_ROOT_DIR" "$mode_dir"
    install_dir "$csm_backup"   "$mode_dir"
    install_dir "$csm_common"   "$mode_dir"
    install_dir "$csm_stacks"   "$mode_dir"
    install_dir "$csm_configs"  "$mode_dir"
    install_dir "$csm_secrets"  "$mode_dir"
}

setup_files() {
    log STEP "Installing CSM core files..."
    for src in "${!files_to_install[@]}"; do
        local dest_dir="${files_to_install[$src]}"
        # Pick the right mode: .conf files get conf_mode, others get exec_mode
        local mode
        [[ "$src" == *.conf ]] && mode="$mode_conf" || mode="$mode_exec"
        install_file "$src" "$dest_dir" "$mode"
    done
}

# =============================================================================
# 9. SYMLINKS
# =============================================================================

setup_symlinks() {
    log STEP "Setting up symlinks..."

    # ~/stacks  → CSM_ROOT_DIR
    local target_dir="$CSM_ROOT_DIR"
    if [[ ! -e "$link_path" && ! -L "$link_path" ]]; then
        ln -s "$target_dir" "$link_path"
        log INFO "Created symlink: $link_path → $target_dir"
    elif [[ -L "$link_path" ]]; then
        local current_target
        current_target="$(readlink "$link_path")"
        if [[ "$current_target" != "$target_dir" ]]; then
            log WARN "Symlink $link_path points to $current_target (expected $target_dir)"
            confirm_no "Update symlink to point to $target_dir?" && {
                rm -f "$link_path"
                ln -s "$target_dir" "$link_path"
                log INFO "Symlink updated."
            }
        else
            log PASS "Symlink $link_path is correct."
        fi
    else
        log WARN "$link_path exists and is not a symlink – leaving it alone."
    fi

    # /usr/local/bin/csm  → CSM_ROOT_DIR/csm.sh
    local csm_bin="${CSM_ROOT_DIR}/csm.sh"
    if [[ ! -e "$bin_link" && ! -L "$bin_link" ]]; then
        $var_sudo ln -sf "$csm_bin" "$bin_link"
        log INFO "Created symlink: $bin_link → $csm_bin"
    elif [[ -L "$bin_link" ]]; then
        log PASS "Symlink $bin_link already exists."
    else
        log WARN "$bin_link exists and is not a symlink – leaving it alone."
    fi
}

# =============================================================================
# 10. OWNERSHIP
# =============================================================================

set_ownership() {
    log STEP "Setting group on ${CSM_ROOT_DIR} to ${csm_group}..."
    [ "$(get_group "$CSM_ROOT_DIR")" != "$csm_group" ] && $var_sudo chgrp "$csm_group" "$CSM_ROOT_DIR"
    [ "$(get_perms "$CSM_ROOT_DIR" | cut -c6)" != "s" ] && $var_sudo chmod g+s "$CSM_ROOT_DIR"
    # $var_sudo chown -R "${csm_uid}:${csm_gid}" "$CSM_ROOT_DIR"
    # log INFO "Owner: ${csm_uid}:${csm_gid}"
}

# =============================================================================
# 11. MAIN
# =============================================================================

main() {
    log STEP "CSM Installer v${INSTALLER_VERSION} – starting"
    log INFO "Install root: ${CSM_ROOT_DIR}"
    log INFO "Invoking user: ${csm_owner} (UID ${csm_uid})"

    detect_pkg_manager
    create_docker_user_group
    install_docker
    check_docker_service
    setup_directories
    setup_files
    setup_symlinks
    set_ownership

    echo ""
    log PASS "CSM installation complete!"
    log INFO "Next steps:"
    log INFO "  1. Edit user config : ${csm_configs}/user.conf"
    log INFO "  2. View your stacks : ${csm_stacks}/"
    log INFO "  3. Get started      : csm --help"
    [[ "$(groups)" != *docker* ]] && \
        log WARN "Remember to log out and back in so your docker group membership takes effect."
}

main "$@"
