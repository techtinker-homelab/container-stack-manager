#!/usr/bin/env bash
# =============================================================================
# csm-install.sh - Container Stack Manager Installer
# =============================================================================

set -euo pipefail

# =============================================================================
# INSTALL SCRIPT OPERATIONS
# =============================================================================

# What this script does (in order):
#   - Validate root / sudo access
#   - Detect OS package manager
#   - Detect or install container runtime (Docker or Podman)
#   - Check / start the container service
#   - Check / create the container runtime group (GID 2000)
#   - Create the CSM directory structure with correct permissions
#   - Install core CSM files
#   - Create ~/stacks symlink pointing to CSM_DIR
#   - Symlink /usr/local/bin/csm → CSM_DIR/.configs/csm.sh
#   - Set final ownership

# =============================================================================
# CREATE LOCKFILE TO PREVENT DUPLICATE CONCURRENT INSTALLATIONS
# =============================================================================

LOCKFILE="/var/lock/csm-install.lock"
if ! command -v flock >/dev/null 2>&1; then
    echo "WARNING: flock not found - install util-linux or coreutils for safety." >&2
    exit 1
fi
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo "Another instance of csm-install.sh is already running." >&2
    exit 1
fi

# =============================================================================
# GLOBAL INSTALLATION VARIABLES, SET TO "1" VIA COMMAND OPTIONS
# =============================================================================

csm_version="0.4.5"

# Install operation flags
dry_run=0
csm_debug=0
force_install=0
uninstall_mode=0

declare -gA user_overrides

# =============================================================================
# ENSURE SCRIPT NOT SOURCED
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
else
    echo "ERROR: This script must be executed directly, not sourced." >&2
    echo "Run: bash csm-install.sh  (or ./csm-install.sh)" >&2
    return 1 2>/dev/null || exit 1
fi

# =============================================================================
# PRIVILEGE CHECK
# =============================================================================

if [[ "$(id -u)" -eq 0 ]]; then
    var_sudo=""
    running_as_root=true
elif command -v sudo >/dev/null 2>&1; then
    var_sudo="sudo"
    running_as_root=false
else
    printf "This installer requires root or sudo. Neither is available."
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
        PASS)       color="${grn}" ;;
        STEP)       color="${mgn}"; if [[ "${csm_debug:-0}" == "0" ]]; then return 0; fi ;;
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

_confirm_yes() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${prompt} [Y/n]: " reply
    case "${reply,,}" in
        y|yes|"") return 0 ;;
        *) return 1 ;;
    esac
}

_confirm_no() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" reply
    if [[ "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1
}

_sanitize_input() {
    local input="$1"
    # Remove dangerous characters that could enable code execution or break sed
    input="${input//\$/}"    # Remove dollar signs
    input="${input//\(/}"    # Remove parentheses
    input="${input//\)/}"
    input="${input//\`/}"    # Remove backticks
    input="${input//|/}"     # Remove pipes (sed delimiter)
    input="${input//\\/}"    # Remove backslashes
    echo "$input"
}

_parse_value() {
    local val="$1"
    val="${val%%#*}"  # Strip comments
    val="${val#"${val%%[![:space:]]*}"}"  # Trim leading spaces
    val="${val%"${val##*[![:space:]]}"}"  # Trim trailing spaces
    # Strip surrounding double quotes if present
    if [[ $val =~ ^\".*\"$ ]]; then val="${val:1:-1}"; fi
    echo "$val"
}

_write_value() {
    local file_path="$1"
    local -n vars_array="$2"  # nameref to the associative array
    _log STEP "_write_value: file_path: $file_path | vars_array: $_vars_array"

    if [[ "$dry_run" == 1 ]]; then
        _log INFO "Would write variables to ${file_path}"
        return 0
    fi

    mkdir -p "$(dirname "$file_path")"
    local temp_file
    temp_file=$(mktemp)
    local written=0
    for var in "${!vars_array[@]}"; do
        local val="${vars_array[$var]}"
        [[ -n "$val" ]] && echo "${var}=${val}" >>"$temp_file" && ((written++))
    done
    cp "$temp_file" "$file_path"
    chown "${csm_uid}:${csm_gid}" "$file_path"
    chmod "$mode_conf" "$file_path"
    rm -f "$temp_file"
    _log INFO "Wrote ${written} values to ${file_path}"
}

# =============================================================================
# CONFIGURATION  (override via env vars before calling the script)
# =============================================================================

_vars_setup() {
    local csm_ini_file="${script_dir}/csm.ini"
    # Global config variables - ordered list and values
    declare -ga csm_var_order
    csm_var_order=(
        CSM_VERSION
        CSM_CONTAINER_RUNTIME
        CSM_STACKS_GID
        CSM_STACKS_UID
        CSM_ROOT_DIR
        CSM_BACKUPS_DIR
        CSM_CONFIGS_DIR
        CSM_SECRETS_DIR
        CSM_TEMPLATES_DIR
        CSM_NETWORK_NAME
        CSM_NETWORK_SUBNET
        CSM_VOLUME_DRIVER
        CSM_VOLUME_LABEL
        CSM_TEMPLATE_SOURCE
        CSM_TEMPLATE_BRANCH
        CSM_TEMPLATE_REPO_NAME
        CSM_TEMPLATE_UPDATE_INTERVAL
        CSM_TEMPLATE_GITLAB_OWNER
        CSM_TEMPLATE_GITLAB_URL
        CSM_TEMPLATE_GITLAB_RAW
        CSM_TEMPLATE_CODEBERG_OWNER
        CSM_TEMPLATE_CODEBERG_URL
        CSM_TEMPLATE_CODEBERG_RAW
        CSM_TEMPLATE_GITHUB_OWNER
        CSM_TEMPLATE_GITHUB_URL
        CSM_TEMPLATE_GITHUB_RAW
        CSM_BACKUP_MAX_AGE
        CSM_BACKUP_COMPRESSION
        CSM_ENV_TEMP
        CSM_ENV_LOCAL
        CSM_ENV_SWARM
        CSM_COMPOSE_TEMP
        CSM_COMPOSE_PROD
    )
    declare -gA csm_vars
    csm_vars[CSM_VERSION]="${csm_version:-undefined}"
    csm_vars[CSM_CONTAINER_RUNTIME]=""
    csm_vars[CSM_STACKS_GID]="2000"
    csm_vars[CSM_STACKS_UID]=""
    csm_vars[CSM_ROOT_DIR]="/srv/stacks"
    csm_vars[CSM_BACKUPS_DIR]="\${CSM_ROOT_DIR}/.backups"
    csm_vars[CSM_CONFIGS_DIR]="\${CSM_ROOT_DIR}/.configs"
    csm_vars[CSM_SECRETS_DIR]="\${CSM_ROOT_DIR}/.secrets"
    csm_vars[CSM_TEMPLATES_DIR]="\${CSM_ROOT_DIR}/.templates"
    csm_vars[CSM_NETWORK_NAME]="csm_network"
    csm_vars[CSM_NETWORK_SUBNET]="172.20.0.0/16"
    csm_vars[CSM_VOLUME_DRIVER]="local"
    csm_vars[CSM_VOLUME_LABEL]="csm-volume"
    csm_vars[CSM_TEMPLATE_SOURCE]="gitlab"
    csm_vars[CSM_TEMPLATE_BRANCH]="main"
    csm_vars[CSM_TEMPLATE_REPO_NAME]="csm-templates"
    csm_vars[CSM_TEMPLATE_UPDATE_INTERVAL]="7"
    csm_vars[CSM_TEMPLATE_GITLAB_OWNER]="techtinker"
    csm_vars[CSM_TEMPLATE_GITLAB_URL]="https://gitlab.com/\${CSM_TEMPLATE_GITLAB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    csm_vars[CSM_TEMPLATE_GITLAB_RAW]="https://gitlab.com/\${CSM_TEMPLATE_GITLAB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/-/\raw/\${CSM_TEMPLATE_BRANCH}"
    csm_vars[CSM_TEMPLATE_CODEBERG_OWNER]="techtinker"
    csm_vars[CSM_TEMPLATE_CODEBERG_URL]="https://codeberg.org/\${CSM_TEMPLATE_CODEBERG_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    csm_vars[CSM_TEMPLATE_CODEBERG_RAW]="https://codeberg.org/\${CSM_TEMPLATE_CODEBERG_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/raw/\branch/\${CSM_TEMPLATE_BRANCH}"
    csm_vars[CSM_TEMPLATE_GITHUB_OWNER]="techtinker-homelab"
    csm_vars[CSM_TEMPLATE_GITHUB_URL]="https://github.com/\${CSM_TEMPLATE_GITHUB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    csm_vars[CSM_TEMPLATE_GITHUB_RAW]="https://raw.githubusercontent.com/\${CSM_TEMPLATE_GITHUB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/\${CSM_TEMPLATE_BRANCH}"
    csm_vars[CSM_BACKUP_MAX_AGE]="30"
    csm_vars[CSM_BACKUP_COMPRESSION]="gz"
    csm_vars[CSM_ENV_TEMP]="example.env"
    csm_vars[CSM_ENV_LOCAL]="local.env"
    csm_vars[CSM_ENV_SWARM]="swarm.env"
    csm_vars[CSM_COMPOSE_TEMP]="local-compose.yml"
    csm_vars[CSM_COMPOSE_PROD]="swarm-compose.yml"

    # Create fresh csm.ini if it does not exist (fallback defaults)
    if [[ ! -f "$csm_ini_file" ]]; then
        local csm_ini_temp="${script_dir}/../csm.ini"   # template lives next to the repo root
        if [[ -f "$csm_ini_temp" ]]; then
            cp "$csm_ini_temp" "$csm_ini_file"
            _log STEP "Copied default config template to $csm_ini_file"
        else
            {   _log STEP "# Default CSM configuration - generated by csm-install.sh"
                _log STEP "# csm_version = ${csm_vars[CSM_VERSION]:-undefined}"
                for var in "${csm_var_order[@]}"; do
                    echo "${var}=${csm_vars[$var]}"
                done
            } >"$csm_ini_file"
            _log STEP "Created minimal config file at: $csm_ini_file"
        fi
    fi

    # Load defaults from csm.ini
    source "$csm_ini_file"
    _log STEP "Loaded defaults from $csm_ini_file"

    # Store all CSM_* values in associative array for unified handling
    declare -gA csm_values
    while IFS='=' read -r key val; do
        if [[ -n "$key" ]]; then
            val="$(_parse_value "$val")"
            # Basic validation
            case "$key" in
                CSM_BACKUP_MAX_AGE|CSM_STACKS_GID|CSM_STACKS_UID|CSM_TEMPLATE_UPDATE_INTERVAL)
                    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
                        _log STEP "Invalid numeric value for $key: '$val', using default"
                        val="${csm_vars[$key]:-}"
                    fi
                    ;;
                CSM_ROOT_DIR)
                    if [[ -n "$val" && "$val" != /* ]]; then
                        _log STEP "CSM_ROOT_DIR must be absolute path: '$val', using default"
                        val="${csm_vars[$key]:-}"
                    fi
                    ;;
            esac
            csm_values[$key]="$val"
        fi
    done < <(grep -v '^#' "$csm_ini_file" | grep '=')
    _log STEP "Loaded ${#csm_values[@]} config values from csm.ini"

    # User overrides (populated in _user_input, written to user.conf in _setup_files)
    declare -gA user_overrides

    # Map CSM_* names to internal vars with defaults
    csm_version="${CSM_VERSION:-undefined}"
    csm_runtime="${CSM_CONTAINER_RUNTIME:-docker}"
    csm_net_name="${CSM_NETWORK_NAME:-csm_network}"
    csm_gid="${csm_gid:-${CSM_STACKS_GID:-2000}}"
    csm_uid="${CSM_STACKS_UID:-${SUDO_UID:-$(id -u)}}"

    # Map CSM_ dir vars to internal vars with defaults
    csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
    csm_backups="${CSM_BACKUPS_DIR:-${csm_dir}/.backups}"
    csm_configs="${CSM_CONFIGS_DIR:-${csm_dir}/.configs}"
    csm_secrets="${CSM_SECRETS_DIR:-${csm_dir}/.secrets}"
    csm_templates="${CSM_TEMPLATES_DIR:-${csm_dir}/.templates}"

    readonly csm_user_conf="${csm_configs}/user.conf"

    # Export internal names for use by other functions
    export csm_runtime csm_gid csm_uid csm_version csm_net_name \
            csm_dir csm_backups csm_configs csm_secrets csm_templates

    # Owner/group setup (runtime-dependent, so after sourcing)
    csm_owner="${SUDO_USER:-$(id -un)}"
    csm_group="docker"   # default, overridden after runtime detection
    csm_gid="${CSM_STACKS_GID:-2000}"  # re-assign if user override

    readonly csm_link="${HOME}/stacks"
    readonly bin_link="/usr/local/bin/csm"

    # Permission modes (move to csm.ini if configurable, else keep here)
    readonly mode_exec="770"
    readonly mode_conf="660"
    readonly mode_auth="600"

    # Files to install (csm.ini is handled in _vars_setup, user.conf created on first run)
    declare -A files_to_install=(
        ["${script_dir}/csm.sh"]="${csm_configs}/"
        ["${script_dir}/csm.ini"]="${csm_configs}/"
    )
    _log STEP "_vars_setup complete: runtime=${csm_runtime}, dir=${csm_dir}"
}

_user_input() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    _log STEP "_user_input: csm_configs=${csm_configs}"

    # Ordered list of user prompted vars
    declare -ga csm_var_prompt
    csm_var_prompt=(
        CSM_CONTAINER_RUNTIME
        CSM_STACKS_GID
        CSM_STACKS_UID
        CSM_ROOT_DIR
        CSM_NETWORK_NAME
        CSM_NETWORK_SUBNET
        CSM_VOLUME_DRIVER
        CSM_BACKUP_MAX_AGE
        CSM_BACKUP_COMPRESSION
        CSM_ENV_LOCAL
        CSM_ENV_SWARM
        )
        # Templates are not yet implemented
        # CSM_TEMPLATE_SOURCE
        # CSM_TEMPLATE_BRANCH
        # CSM_TEMPLATE_REPO_NAME
        # CSM_TEMPLATE_UPDATE_INTERVAL

    # Ensure user.conf exists with defaults if not present
    local user_conf="${csm_user_conf}"
    if [[ ! -f "$user_conf" ]]; then
        _log STEP "Creating user.conf with defaults from csm.ini"
        cp "${csm_configs}/csm.ini" "$user_conf"
        chown "${csm_uid}:${csm_gid}" "$user_conf"
        chmod "$mode_conf" "$user_conf"
        _log STEP "Created user.conf with default values"
    fi

    # Load existing user.conf
    if [[ -f "$user_conf" ]]; then
        while IFS='=' read -r key val; do
            if [[ -n "$key" ]]; then
                user_overrides[$key]="$(_parse_value "$val")"
            fi
        done < "$user_conf"
        _log STEP "Loaded ${#user_overrides[@]} values from existing user.conf"
    fi

    if _confirm_no "Reset all values to defaults?"; then
        _log STEP "_user_input: resetting to defaults"
        for var in "${csm_var_prompt[@]}"; do
            local default_val="${csm_vars[$var]}"
            # Use detected values for runtime/UID instead of blank defaults
            case "$var" in
                CSM_CONTAINER_RUNTIME) default_val="$csm_runtime" ;;
                CSM_STACKS_UID) default_val="$csm_uid" ;;
            esac
            sed -i "s|^${var}=.*$|${var}=\"${default_val}\"|" "$user_conf"
            user_overrides[$var]="$default_val"
        done
        _log STEP "All values reset to defaults"
    fi
    if _confirm_no "Do you want to manually edit any of the configuration values?"; then
        _log STEP "Press ENTER to keep the current value in brackets."
        local var cur new updated=0
        _log STEP "Prompting for ${#csm_var_prompt[@]} variables..."
        for var in "${csm_var_prompt[@]}"; do
            cur="${user_overrides[$var]:-}"
            [[ -z "$cur" ]] && cur="${csm_values[$var]:-}"
            [[ -z "$cur" ]] && cur="${csm_vars[$var]:-}"
            read -r -p "Current value for ${var} [${cur}]: " new
            # If no input provided, use detected values for runtime/UID
            if [[ -z "$new" ]]; then
                case "$var" in
                    CSM_CONTAINER_RUNTIME) new="$csm_runtime" ;;
                    CSM_STACKS_UID) new="$csm_uid" ;;
                esac
            fi
            if [[ -n "$new" ]]; then
                new="$(_sanitize_input "$new")"
                sed -i "s|^${var}=.*$|${var}=\"${new}\"|" "$user_conf"
                user_overrides[$var]="$new"
                _log STEP "Set ${var}=${new}"
                updated=$((updated + 1))
            fi
        done
        _log STEP "Updated ${updated} values in user.conf"
    fi
}

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

_get_file_info() {
    local file="${1:-}"
    local info=""
    # Try GNU stat first (Linux), fallback to BSD stat
    if info=$(stat -c '%U %G %a' "$file" 2>/dev/null) || info=$(stat -f '%Su %Sg %Lp' "$file" 2>/dev/null); then
        echo "$info"
    fi
}

_get_group() {
    local file="${1:-}"
    stat -c '%G' "$file" 2>/dev/null || stat -f '%Sg' "$file"
}

_get_perms() {
    local file="${1:-}"
    stat -c '%A' "$file" 2>/dev/null || stat -f '%Sp' "$file"
}

# =============================================================================
# CONTAINER RUNTIME DETECTION / INSTALLATION
# =============================================================================

_detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        _log PASS "Docker found: $(docker --version)"
        csm_runtime="docker"
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
}

_install_podman() {
    _log STEP "_install_podman: installing via package manager..."
    _install_pkg podman
    _log PASS "Podman installed: $(podman --version)"
    csm_runtime="podman"
}

_install_runtime() {
    if _detect_runtime; then
        _log INFO "Container runtime already installed."
        return 0
    fi

    local runtime="${1:-docker}"
    case "$runtime" in
        docker) _install_docker ;;
        podman) _install_podman ;;
        *) _log EXIT "Unsupported runtime: $runtime" ;;
    esac
}

_detect_swarm() {
    local swarm_state
    swarm_state="$($var_sudo docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
    if [[ "$swarm_state" == "active" ]]; then return 0; else return 1; fi
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
            if [[ $(_detect_swarm) ]]; then
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
# CONTAINER SERVICE CHECK
# =============================================================================

_check_service() {
    _log STEP "_check_service: runtime=$csm_runtime"

    # 1. Detect Init System
    local init_type="unknown"
    if [[ -d /run/systemd/system ]]; then
        init_type="systemd"
    elif [[ -x /sbin/openrc-run ]] || [[ -f /etc/init.d/functions.sh ]]; then
        # OpenRC (Common on Devuan/Alpine)
        init_type="openrc"
    elif [[ -f /etc/init.d/skeleton ]] || [[ -d /etc/init.d ]]; then
        # Traditional SysVinit
        init_type="sysvinit"
    fi

    # 2. Define Internal Helper for status/start
    # Usage: _srv_manager <service_name> <action: status|start>
    _srv_manager() {
        local srv="$1"
        local action="$2"

        case "$init_type" in
            systemd)
                [[ "$action" == "status" ]] && systemctl is-active --quiet "$srv" && return 0
                [[ "$action" == "start" ]] && $var_sudo systemctl start "$srv" && return 0
                ;;
            openrc)
                [[ "$action" == "status" ]] && rc-service "$srv" status >/dev/null 2>&1 && return 0
                [[ "$action" == "start" ]] && $var_sudo rc-service "$srv" start && return 0
                ;;
            sysvinit)
                [[ "$action" == "status" ]] && service "$srv" status >/dev/null 2>&1 && return 0
                [[ "$action" == "start" ]] && $var_sudo service "$srv" start && return 0
                ;;
            *)
                _log WARN "Unknown init system. Manual check required for $srv."
                return 0 # Assume okay to prevent script death
                ;;
        esac
        return 1
    }

    # 3. Runtime Logic
    case "$csm_runtime" in
        docker)
            _log STEP "Checking Docker service via $init_type..."
            if _srv_manager docker status; then
                _log PASS "Docker service is running."
                return 0
            fi

            _log WARN "Docker service is not running."
            if _confirm_yes "Start Docker now?"; then
                _srv_manager docker start \
                    && _log PASS "Docker started." \
                    || _die "Failed to start Docker. Check logs in /var/log/."
            fi
            ;;
        podman)
            # Podman socket logic varies wildly outside systemd
            if [[ "$init_type" == "systemd" ]]; then
                _log STEP "Checking Podman socket (systemd)..."
                if _srv_manager podman.socket status; then
                    _log PASS "Podman socket is active."
                    return 0
                fi
                _confirm_yes "Enable Podman socket?" && {
                    $var_sudo systemctl enable --now podman.socket
                    _log PASS "Podman socket enabled."
                }
            else
                _log INFO "Podman socket management is manual on $init_type."
            fi
            ;;
    esac
}

# =============================================================================
# DOCKER USER / GROUP  (UID/GID 2000, Docker only)
# =============================================================================

_create_group() {
    _log STEP "_create_group: checking if group '$csm_group' (GID ${csm_gid:-2000}) exists..."

    local lgid=${csm_gid:-2000}

    if ! getent group "$csm_group" >/dev/null 2>&1; then
        _log INFO "Group '$csm_group' does not exist"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create group '$csm_group' with GID $lgid"
        else
            _log STEP "_create_group: creating group..."
            $var_sudo groupadd -g "$lgid" "$csm_group" \
                && _log INFO "Created group '$csm_group' (GID $lgid)" \
                || _die "Failed to create group '$csm_group'"
        fi
    else
        _log INFO "Group '$csm_group' (GID $lgid) already exists."
    fi

    # Use the actual GID (may differ if group already existed with different GID)
    csm_gid="$(getent group "$csm_group" | cut -d: -f3)"
    _log STEP "_create_group: resolved csm_gid=$csm_gid"

    local current_user="${SUDO_USER:-$(id -un)}"
    _log STEP "_create_group: checking if user '$current_user' is in group '$csm_group'..."
    if ! groups "$current_user" 2>/dev/null | grep -qw "$csm_group"; then
        _log WARN "User '$current_user' is not in the '$csm_group' group."
        _confirm_yes "Add '$current_user' to '$csm_group'?" && {
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would add user '$current_user' to group '$csm_group'"
            else
                _log STEP "_create_group: running gpasswd -a $current_user $csm_group"
                $var_sudo gpasswd -a "$current_user" "$csm_group"
                _log INFO "User added. Log out and back in for this to take effect."
            fi
        }
    else
        _log PASS "User '$current_user' is in the '$csm_group' group."
    fi
}

# =============================================================================
# CONTAINER DIRECTORIES AND NETWORKING
# =============================================================================

_install_dir() {
    local tgt="${1:-}" mode="${2:-}"
    if [[ ! -d "$tgt" ]]; then
        _log STEP "_install_dir: creating $tgt (mode=$mode)"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create directory '$tgt' (mode=$mode)"
        else
            $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -d "$tgt"
            _log INFO "Created: $tgt"
        fi
    fi
}

_install_file() {
    local src="${1:-}" dest_dir="${2:-}" mode="${3:-}" flag="${4:-}"
    local filename=$(basename "$src")

    if [[ -f "$src" ]]; then
        _log STEP "_install_file: installing $filename (mode=$mode)"
        case "$flag" in
            -f | --force)
                # Overwrite target file, -p: preserve timestamps
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -p "$src" "$dest_dir/"
                ;;
            *)
                # Only copy if changed, -C: only copy if different
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -C "$src" "$dest_dir/"
        esac
        _log INFO "Installed: $filename → $dest_dir"
    else
        _log WARN "Source file missing: $src"
    fi
}

_setup_folders() {
    _log STEP "_setup_folders: initializing structure at ${CSM_ROOT_DIR}"
    local target_dirs=(
        "${CSM_ROOT_DIR}"
        "${CSM_BACKUPS_DIR}"
        "${CSM_CONFIGS_DIR}"
        "${CSM_SECRETS_DIR}"
        "${CSM_TEMPLATES_DIR}"
    )
    for dir in "${target_dirs[@]}"; do
        _install_dir "$dir" "$mode_exec"
    done

    # Set secrets directory to more restrictive permissions
    if [[ -d "$CSM_SECRETS_DIR" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would set secrets directory to mode 700"
        else
            $var_sudo chmod $mode_auth "$CSM_SECRETS_DIR"
        fi
    fi
}

_setup_files() {
    _log STEP "_setup_files: installing CSM core files..."

    # Install csm.sh
    if [[ -f "${script_dir}/csm.sh" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would install csm.sh to ${csm_configs}/ (mode: $mode_exec)"
        else
            local option=""
            if [[ "${force_install}" == 1 ]]; then option="--force"; fi
            _install_file "${script_dir}/csm.sh" "${csm_configs}/" "${mode_exec}" "${option}"
        fi
    fi

    # Install csm.ini if not already there
    local csm_ini_installed="${csm_configs}/csm.ini"
    if [[ ! -f "$csm_ini_installed" ]]; then
        if [[ -f "${script_dir}/csm.ini" ]]; then
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would install csm.ini to ${csm_configs}/ (mode: $mode_conf)"
            else
                _install_file "${script_dir}/csm.ini" "${csm_configs}/" "$mode_conf"
            fi
        fi
    fi

    # # Create/ensure user.conf exists for user overrides
    # local user_conf="${csm_configs}/user.conf"
    # local user_conf_global="${csm_user_conf}"
    # _log STEP "user.conf exists: $([[ -f "$user_conf" ]] && echo yes || echo no)"
    # _log STEP "user_overrides count: ${#user_overrides[@]}"
    # _log STEP "force_install: $force_install"
    # if [[ ! -f "$user_conf_global" || "$force_install" == 1 || "${#user_overrides[@]}" -gt 0 ]]; then
    #     if [[ "$dry_run" == 1 ]]; then
    #         _log INFO "Would create user.conf at ${csm_configs}/ (mode: $mode_conf)"
    #         _log INFO "Would create user.conf at ${user_conf_global} (mode: $mode_conf)"
    #     else
    #         if [[ ! -f "$user_conf" ]]; then
    #             $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" /dev/null "$user_conf"
    #         fi
    #         mkdir -p "$(dirname "$user_conf_global")"
    #         if [[ ! -f "$user_conf_global" ]]; then
    #             install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" /dev/null "$user_conf_global"
    #         fi
    #         # Merge csm_values with user_overrides (user overrides take precedence)
    #         declare -A merged_values
    #         for var in "${csm_var_order[@]}"; do
    #             local val="${csm_values[$var]:-}"
    #             [[ -n "$val" ]] && merged_values[$var]="$val"
    #         done
    #         for var in "${!user_overrides[@]}"; do
    #             local val="${user_overrides[$var]:-}"
    #             [[ -n "$val" ]] && merged_values[$var]="$val"
    #         done
    #         _log STEP "merged_values contains ${#merged_values[@]} values"
    #         for var in "${csm_var_order[@]}"; do
    #             local val="${merged_values[$var]:-}"
    #             [[ -n "$val" ]] && _log INFO "will_write: ${var}=${val}"
    #         done
    #         # Write merged values to file once (in order from csm_var_order)
    #         : >"$user_conf"
    #         : >"$user_conf_global"
    #         local written=0
    #         for var in "${csm_var_order[@]}"; do
    #             local val="${merged_values[$var]:-}"
    #             [[ -n "$val" ]] && echo "${var}=${val}" >>"$user_conf" && echo "${var}=${val}" >>"$user_conf_global" && ((written++))
    #         done
    #         _log INFO "Wrote ${written} values to user.conf files"
    #     fi
    # else
    #     _log INFO "user.conf already exists, using existing values"
    # fi

    # Handle Env Templates
    local env_example="${script_dir}/example.env"
    local env_local="${csm_configs}/.local.env"
    local env_swarm="${csm_configs}/.swarm.env"
    if [[ -f "$env_example" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would install example.env to ${csm_configs}/"
            _log INFO "Would create .local.env and .swarm.env from template"
        else
            _install_file "$env_example" "${csm_configs}/" "$mode_conf"
            if [[ ! -f "$env_local" || "$force_install" == 1 ]]; then
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$env_example" "$env_local"
            fi
            if [[ ! -f "$env_swarm" || "$force_install" == 1 ]]; then
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$env_example" "$env_swarm"
            fi
            _log INFO "Created/Overwrote local and swarm .env templates"
        fi
    fi

    # Handle Compose Templates
    local compose_example="${script_dir}/example-compose.yml"
    local compose_local="${csm_configs}/local-compose.yml"
    local compose_swarm="${csm_configs}/swarm-compose.yml"
    if [[ -f "$compose_example" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would install example-compose.yml to ${csm_configs}/"
            _log INFO "Would create local-compose.yml and swarm-compose.yml from template"
        else
            _install_file "$compose_example" "${csm_configs}/" "$mode_conf"
            if [[ ! -f "$compose_local" || "$force_install" == 1 ]]; then
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$compose_example" "$compose_local"
            fi
            if [[ ! -f "$compose_swarm" || "$force_install" == 1 ]]; then
                $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$compose_example" "$compose_swarm"
            fi
            _log INFO "Created/Overwrote local and swarm compose templates"
        fi
    fi
}

_setup_network() {
    local net_name="${CSM_NETWORK_NAME:-csm_network}"
    _log STEP "_setup_network: ensuring network '$net_name' exists..."

    # Determine binary based on detected runtime
    local cmd="$csm_runtime"

    # Check for no container runtime
    if [[ -z "$cmd" ]]; then
        _log ERROR "No container runtime detected. Skipping network setup."
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would skip network creation (no runtime)"
        fi
        return 1
    fi

    # Check if the network already exists
    if $var_sudo "$cmd" network inspect "$net_name" >/dev/null 2>&1; then
        _log PASS "Custom network '$net_name' exists."
        return 0
    fi

    # Network doesn't exist - create it
    _log INFO "Network '$net_name' does not exist"
    case "$csm_runtime" in
        podman)
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would create Podman network '$net_name'"
            else
                _log STEP "_setup_network: creating podman network $net_name"
                $var_sudo podman network create "$net_name" >/dev/null 2>&1 \
                    && _log PASS "Podman network '$net_name' created." \
                    || _log WARN "Failed to create Podman network '$net_name'."
            fi
            ;;
        docker)
            # Check if Swarm is active to determine network driver
            if [[ $(_detect_swarm) ]]; then
                if [[ "$dry_run" == 1 ]]; then
                    _log INFO "Would create Docker Swarm overlay network '$net_name'"
                else
                    _log STEP "_setup_network: creating docker swarm overlay network $net_name"
                    $var_sudo docker network create --driver overlay --attachable "$net_name" >/dev/null 2>&1 \
                        && _log PASS "Docker Swarm network '$net_name' created." \
                        || _log WARN "Failed to create Docker Swarm network '$net_name'."
                fi
            else
                if [[ "$dry_run" == 1 ]]; then
                    _log INFO "Would create Docker bridge network '$net_name'"
                else
                    _log STEP "_setup_network: creating docker bridge network $net_name"
                    $var_sudo docker network create "$net_name" >/dev/null 2>&1 \
                        && _log PASS "Docker network '$net_name' created." \
                        || _log WARN "Failed to create Docker network '$net_name'."
                fi
            fi
            ;;
        *)
            _log WARN "Unsupported runtime '$csm_runtime' for network setup."
            ;;
    esac
}

# =============================================================================
# SYMLINKS
# =============================================================================

_setup_symlinks() {
    _log STEP "_setup_symlinks: checking and creating symlinks"
    local links=(
        "${HOME}/stacks:${CSM_ROOT_DIR}"
        "/usr/local/bin/csm:${CSM_CONFIGS_DIR}/csm.sh"
    )

    for link_spec in "${links[@]}"; do
        local source="${link_spec%:*}" target="${link_spec#*:}"

        if [[ -L "$source" ]]; then
            if [[ "$(readlink -f "$source")" != "$(readlink -f "$target")" ]]; then
                _log WARN "Symlink $source is misaligned."
                if [[ "$dry_run" == 1 ]]; then
                    _log INFO "Would correct symlink: $source -> $target"
                else
                    [[ "$source" == /usr/local/bin/* ]] && $var_sudo rm -f "$source" || rm -f "$source"
                    [[ "$source" == /usr/local/bin/* ]] && $var_sudo ln -sf "$target" "$source" || ln -sf "$target" "$source"
                    _log INFO "Corrected symlink: $source"
                fi
            fi
        elif [[ ! -e "$source" ]]; then
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would create symlink: $source -> $target"
            else
                [[ "$source" == /usr/local/bin/* ]] && $var_sudo ln -sf "$target" "$source" || ln -sf "$target" "$source"
                _log INFO "Created symlink: $source"
            fi
        fi
    done
}

_verify_ownership() {
    _log STEP "_verify_ownership: checking current ownership of ${csm_dir}..."
    local current_group current_perms owner

    read -r owner current_group <<< "$(_get_file_info "$csm_dir")"
    _log INFO "Current group: $current_group, target: $csm_group"

    if [[ "$current_group" != "$csm_group" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would run: chgrp $csm_group $csm_dir"
        else
            _log STEP "_verify_ownership: running chgrp $csm_group $csm_dir"
            $var_sudo chgrp "$csm_group" "$csm_dir"
        fi
    fi

    current_perms="$(_get_perms "$csm_dir")"
    if [[ "$current_perms" != "drwxrws---" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would run: chmod $mode_exec $csm_dir && chmod g+s $csm_dir"
        else
            if $var_sudo chmod $mode_exec "$csm_dir" && $var_sudo chmod g+s "$csm_dir"; then
                _log STEP "_verify_ownership: set permissions to $mode_exec with setgid on $csm_dir"
            else
                _log WARN "Failed to set permissions on $csm_dir"
            fi
        fi
    fi

    _log INFO "Current perms: $(_get_perms "$csm_dir")"
}

# =============================================================================
# UNINSTALL
# =============================================================================

_uninstall_csm() {
    _log WARN "Starting CSM ${red}un${ylw}installation..."
    _log INFO "This will remove the core script and symlinks."
    if [[ "$force_uninstall" == 0 ]]; then
        _log INFO "Your stacks, user.conf, and templates will NOT be modified."
    else
        _log INFO "Your stacks will not be touched, but user.conf and templates, will be removed."
    fi

    _confirm_yes "Proceed with uninstallation?" || { _log INFO "Cancelled."; exit 0; }

    # Remove Symlinks
    if [[ -L "$bin_link" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove binary symlink: $bin_link"
        else
            _log STEP "Removing binary symlink: $bin_link"
            $var_sudo rm -f "$bin_link"
        fi
    else
        _log INFO "Binary symlink $bin_link does not exist"
    fi

    if [[ -L "$csm_link" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove home symlink: $csm_link"
        else
            _log STEP "Removing home directory symlink: $csm_link"
            rm -f "$csm_link"
        fi
    else
        _log INFO "Home symlink $csm_link does not exist"
    fi

    # Remove Core Engine Files
    if [[ -f "${csm_configs}/csm.sh" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove: ${csm_configs}/csm.sh"
        else
            _log STEP "Removing core script: ${csm_configs}/csm.sh"
            $var_sudo rm -f "${csm_configs}/csm.sh"
        fi
    else
        _log INFO "File ${csm_configs}/csm.sh does not exist"
    fi

    if [[ -f "${csm_configs}/csm.ini" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove: ${csm_configs}/csm.ini"
        else
            _log STEP "Removing default config: ${csm_configs}/csm.ini"
            $var_sudo rm -f "${csm_configs}/csm.ini"
        fi
    else
        _log INFO "File ${csm_configs}/csm.ini does not exist"
    fi

    # Remove user config and templates if force mode
    if [[ "$force_install" == 1 ]]; then
        _log WARN "Force mode: Removing user config and templates."
        for file in "${csm_configs}/user.conf" "${csm_configs}/example.env" "${csm_configs}/local-compose.yml" "${csm_configs}/swarm-compose.yml" "${csm_configs}/.local.env" "${csm_configs}/.swarm.env"; do
            if [[ -f "$file" ]]; then
                if [[ "$dry_run" == 1 ]]; then
                    _log INFO "Would remove: $file"
                else
                    _log STEP "Removing: $file"
                    $var_sudo rm -f "$file"
                fi
            fi
        done
    fi

    if [[ "$dry_run" != 1 ]]; then
        _log PASS "CSM core files and symlinks have been removed."
        _log INFO "Note: The container runtime, groups, and ${csm_dir} directories remain intact."
    fi
    exit 0
}

_install_csm() {
    _log INFO "Container Stack Manager v${CSM_VERSION} - installer starting"
    _log INFO "Invoking user: ${csm_owner} (UID ${csm_uid})"
    _log INFO "Install path: ${csm_dir}"

    if [[ "$force_install" == 1 ]]; then
        _log WARN "FORCE MODE ACTIVE: Existing configs will be overwritten and prompts bypassed."
    fi

    _detect_pkg_manager
    _create_group
    _install_runtime
    _check_service
    _setup_network
    _setup_folders
    _setup_files
    _user_input
    _setup_symlinks
    _verify_ownership
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) Installer v${CSM_VERSION}${rst}

${bld}Usage:${rst} ${script_dir}/csm-install.sh [options]

${bld}Options:${rst}
    -b | --debug        Enable debug output.
    -d | --dry-run      Dry run mode: show what would be done without making changes.
    -f | --force        Overwrite script and config files without confirmation.
    -h | --help         Show this help message.
    -u | --uninstall    Uninstall all CSM scripts and unmodified config files.
    -V | --version      Show installer version.

${bld}Examples:${rst}
    ${script_dir}/csm-install.sh -f          # Force install, skip prompts
    ${script_dir}/csm-install.sh -d          # Dry run to see what would happen
    ${script_dir}/csm-install.sh -fdx        # Force install, dry-run, debug
    ${script_dir}/csm-install.sh --uninstall # Uninstall CSM

${bld}Container Stack Manager Installer version:${rst} ${ylw}${CSM_VERSION}${rst}
EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    _color_setup

    # Parse arguments - support both short (-f) and long (--force) options
    local opts
    opts=$(getopt -o bdfhuV -l debug,dry-run,force,help,uninstall,version -n "$0" -- "$@") || {
        show_help
        exit 1
    }
    eval set -- "$opts"

    while true; do
        case "$1" in
            -b|--debug)
                csm_debug=1
                shift
                ;;
            -d|--dry-run)
                dry_run=1
                _log INFO "DRY RUN MODE: No changes will be made."
                shift
                ;;
            -f|--force)
                force_install=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -u|--uninstall)
                uninstall_mode=1
                shift
                ;;
            -V|--version)
                _log PASS "Container Stack Manager version: ${CSM_VERSION}"
                exit 0
                ;;
            --)
                shift
                break
                ;;
        esac
    done

    # Set up variables
    _vars_setup

    # Trigger install or uninstall
    if [[ "$uninstall_mode" == 1 ]]; then
        _uninstall_csm
    else
        _install_csm

        echo ""
        _log PASS "CSM installation complete!"
        echo ""
        _log INFO "Next steps:"
        _log INFO "  1. Edit csm.ini defaults or user.conf : ${csm_configs}/"
        _log INFO "  2. View your stacks : ${csm_dir}/"
        _log INFO "  3. Get started      : csm --help"
        # Check if the invoking user is in the container group (for logout reminder)
        local check_user="${SUDO_USER:-$USER}"
        if ! groups "$check_user" 2>/dev/null | grep -qw "$csm_group"; then
            _log WARN "Remember to log out and back in so your $csm_group group membership takes effect."
        fi

    fi
}

main "$@"
