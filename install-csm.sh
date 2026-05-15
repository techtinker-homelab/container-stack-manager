#!/usr/bin/env bash
# =============================================================================
# install-csm.sh - Container Stack Manager Installer
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
# GLOBAL INSTALLATION VARIABLES, SET TO "1" VIA COMMAND OPTIONS
# =============================================================================

csm_version="0.5.2"

# Install operation flags
dry_run=0
csm_debug=0
force_install=0
uninstall_mode=0

# =============================================================================
# ENSURE SCRIPT NOT SOURCED
# =============================================================================

# Enforce Bash; define script path/file on first run
if [[ -n "${BASH_VERSION:-}" ]]; then
    script_path="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" || "${BASH_SOURCE}")")" && pwd)"
    script_file="$(basename "${BASH_SOURCE[0]}")"
    readonly script_path script_file
else
    echo "ERROR: This installer must be executed with Bash." >&2
    echo "Run: bash ${0}  (or ./${0})" >&2
    exit 1
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
# REQUIRED SETUP VARIABLE VALUES
# =============================================================================

# NOTE: Change these to work on your intended container host
var_defaults() {
    CSM_VERSION="${CSM_VERSION:-${csm_version:-undefined}}"

    # Container runtime (docker or podman, leave blank to choose during installation)
    CSM_RUNTIME="${CSM_RUNTIME:-docker}"

    # Stacks group and user (blank so current user id is used)
    CSM_GID="${CSM_GID:-2000}"
    CSM_UID="${CSM_UID:-${SUDO_UID:-$(id -u)}}"

    # Root directory for all stack files
    CSM_DIR="${CSM_DIR:-/srv/stacks}"
    CSM_BACKUPS="${CSM_DIR}/.backups"
    CSM_CONFIGS="${CSM_DIR}/.configs"
    CSM_SECRETS="${CSM_DIR}/.secrets"
    CSM_TEMPLATES="${CSM_DIR}/.templates"

    # File templates
    CSM_CORE_FILE="csm.sh"
    CSM_ENV_LOCAL="local.env"
    CSM_ENV_SWARM="swarm.env"
    CSM_YML_LOCAL="local.yml"
    CSM_YML_SWARM="swarm.yml"
    CSM_CONF_FILE="user.conf"

    # Container orchestration settings
    CSM_BACKUP_MAX_AGE=30
    CSM_BACKUP_COMPRESSION="zip"
    CSM_NET_NAME="external_edge"
    CSM_NET_CIDR="172.20.0.0/16"
    CSM_VOLUME_LABEL="csm_volume"

    # Stack template settings
    CSM_TEMPLATE_SOURCE="gitlab"
    CSM_TEMPLATE_BRANCH="main"
    CSM_TEMPLATE_REPO_NAME="csm_templates"
    CSM_TEMPLATE_UPDATE_INTERVAL=7
    CSM_TEMPLATE_CODEBERG_OWNER="techtinker"
    CSM_TEMPLATE_CODEBERG_URL="https://codeberg.org/\${CSM_TEMPLATE_CODEBERG_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    CSM_TEMPLATE_CODEBERG_RAW="https://codeberg.org/\${CSM_TEMPLATE_CODEBERG_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/raw/branch/\${CSM_TEMPLATE_BRANCH}"
    CSM_TEMPLATE_GITHUB_OWNER='techtinker-homelab'
    CSM_TEMPLATE_GITHUB_URL="https://github.com/\${CSM_TEMPLATE_GITHUB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    CSM_TEMPLATE_GITHUB_RAW="https://raw.githubusercontent.com/\${CSM_TEMPLATE_GITHUB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/\${CSM_TEMPLATE_BRANCH}"
    CSM_TEMPLATE_GITLAB_OWNER="techtinker"
    CSM_TEMPLATE_GITLAB_URL="https://gitlab.com/\${CSM_TEMPLATE_GITLAB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}"
    CSM_TEMPLATE_GITLAB_RAW="https://gitlab.com/\${CSM_TEMPLATE_GITLAB_OWNER}/\${CSM_TEMPLATE_REPO_NAME}/-/raw/\${CSM_TEMPLATE_BRANCH}"

    # Folders list to be created
    declare -ga dirs_list=(
        "${CSM_DIR}"        # "/srv/stacks"
        "${CSM_BACKUPS}"    # "/srv/stacks/.backups"
        "${CSM_CONFIGS}"    # "/srv/stacks/.configs"
        "${CSM_SECRETS}"    # "/srv/stacks/.secrets"
        "${CSM_TEMPLATES}"  # "/srv/stacks/.templates"
    )

    # Files list to be copied or created
    declare -ga file_list=(
        "${CSM_ENV_LOCAL}"  # "local.env"
        "${CSM_ENV_SWARM}"  # "swarm.env"
        "${CSM_YML_LOCAL}"  # "local.yml"
        "${CSM_YML_SWARM}"  # "swarm.yml"
        "${CSM_CORE_FILE}"  # "csm.sh"
    )
}

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
    printf " %s%s%-4s >> %s%s%s %s%s<<%s\n" \
        "${color}" "${bld}" "${level}" "${prefix}" "${rst}" "${message}" "${color}" "${bld}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_die() { _log FAIL "$1"; exit 1; }

_detect_os() {
    os_type=$(uname -s)
}

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
# VARIABLES SETUP
# =============================================================================
# NOTE: override via env vars before calling the script

_vars_setup() {
    # Set default values
    var_defaults

    # Variable order for iteration
    declare -ga csm_var_order
    csm_var_order=(
        CSM_VERSION
        CSM_RUNTIME
        CSM_GID
        CSM_UID
        CSM_DIR
        CSM_BACKUPS
        CSM_CONFIGS
        CSM_SECRETS
        CSM_TEMPLATES
        CSM_NET_NAME
        CSM_NET_CIDR
        CSM_VOLUME_LABEL
        CSM_BACKUP_MAX_AGE
        CSM_BACKUP_COMPRESSION
        CSM_ENV_LOCAL
        CSM_ENV_SWARM
        CSM_YML_LOCAL
        CSM_YML_SWARM
        CSM_CONF_FILE
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
    )

    # Source ${CSM_CONF_FILE} to override defaults if it exists
    csm_user_conf="${CSM_CONFIGS}/${CSM_CONF_FILE}"
    if [[ -f "$csm_user_conf" ]]; then
        source "$csm_user_conf"
        _log STEP "Loaded user overrides from $csm_user_conf"
    else
        _log STEP "No ${CSM_CONF_FILE} found, using defaults"
    fi

    # Basic validation of loaded values
    if ! [[ "${CSM_BACKUP_MAX_AGE}" =~ ^[0-9]+$ ]]; then
        _log STEP "Invalid CSM_BACKUP_MAX_AGE: '${CSM_BACKUP_MAX_AGE}', using default"
        CSM_BACKUP_MAX_AGE="30"
    fi
    if ! [[ "${CSM_GID}" =~ ^[0-9]+$ ]]; then
        _log STEP "Invalid CSM_GID: '${CSM_GID}', using default"
        CSM_GID="2000"
    fi
    if ! [[ "${CSM_UID}" =~ ^[0-9]+$ ]] && [[ -n "${CSM_UID}" ]]; then
        _log STEP "Invalid CSM_UID: '${CSM_UID}', using default"
        CSM_UID=""
    fi
    if ! [[ "${CSM_TEMPLATE_UPDATE_INTERVAL}" =~ ^[0-9]+$ ]]; then
        _log STEP "Invalid CSM_TEMPLATE_UPDATE_INTERVAL: '${CSM_TEMPLATE_UPDATE_INTERVAL}', using default"
        CSM_TEMPLATE_UPDATE_INTERVAL="7"
    fi
    # Validate CSM_DIR: must be absolute and not in script directory
    if [[ -n "${CSM_DIR}" && ("${CSM_DIR}" != /* || "${CSM_DIR}" == "${script_path}"* || "${CSM_DIR}" == *"${script_file}"*) ]]; then
        _log STEP "Invalid CSM_DIR: '${CSM_DIR}', using default: '/srv/stacks'"
        CSM_DIR="/srv/stacks"
    fi

    # Map CSM_* to internal csm_* variables (with variable expansion)
    csm_version="${CSM_VERSION:-${csm_version:-undefined}}"
    csm_runtime="${CSM_RUNTIME:-docker}"
    csm_gid="${CSM_GID:-2000}"
    csm_uid="${CSM_UID:-${SUDO_UID:-$(id -u)}}"
    csm_dir="${CSM_DIR:-/srv/stacks}"
    csm_backups="$(eval echo "${CSM_BACKUPS}")"
    csm_configs="$(eval echo "${CSM_CONFIGS}")"
    csm_secrets="$(eval echo "${CSM_SECRETS}")"
    csm_templates="$(eval echo "${CSM_TEMPLATES}")"
    csm_network="${CSM_NET_NAME:-csm_network}"

    # Owner/group setup (runtime-dependent, so after sourcing)
    csm_owner="${SUDO_USER:-$(id -un)}"
    csm_group="${CSM_GROUP:-docker}"   # default, overridden after runtime detection

    # After the Bash guard
    declare -gA readonly_list=(
        [csm_link]="${HOME}/stacks"
        [bin_link]="/usr/local/bin/csm"
        [mode_auth]="600"
        [mode_conf]="660"
        [mode_exec]="770"
    )
    for var in "${!readonly_list[@]}"; do
        if [[ -z "${!var+x}" ]]; then
            declare -gr "$var"="${readonly_list[$var]}"
        fi
    done
    _log STEP "_vars_setup complete: runtime=${csm_runtime}, dir=${csm_dir}"
}

_user_input() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    echo
    _log STEP "_user_input: csm_configs=${csm_configs}"

    # Ordered list of user prompted vars
    declare -ga csm_var_prompt
    csm_var_prompt=(
        CSM_GID
        CSM_UID
        CSM_DIR
        CSM_RUNTIME
        CSM_NET_NAME
        CSM_BACKUP_MAX_AGE
        CSM_BACKUP_COMPRESSION
        )

    # Ensure ${CSM_CONF_FILE} exists with current values if not present
    local user_conf="${csm_user_conf}"
    local user_conf_existed=false
    if [[ -f "$user_conf" ]]; then
        user_conf_existed=true
    else
        _log STEP "Creating ${CSM_CONF_FILE} with current values"
        mkdir -p "$(dirname "$user_conf")"
        for var in "${csm_var_order[@]}"; do
            echo "${var}=${!var}" >> "$user_conf"
        done
        chown "${csm_uid}:${csm_gid}" "$user_conf"
        chmod "$mode_conf" "$user_conf"
        _log STEP "Created ${CSM_CONF_FILE} with current values"
    fi

    if [[ "$user_conf_existed" == true ]] && _confirm_no "Reset all values to defaults?"; then
        _log STEP "_user_input: resetting to defaults"
        var_defaults
        # Write defaults to ${CSM_CONF_FILE}
        : > "$user_conf"
        for var in "${csm_var_order[@]}"; do
            echo "${var}=${!var}" >> "$user_conf"
        done
        _log STEP "All values reset to defaults"
    fi

    # Prompt for blank configuration values
    _log STEP "Checking for blank configuration values..."
    for var in "${csm_var_prompt[@]}"; do
        if [[ -z "${!var}" ]]; then
            cur=""
            while read -r -p "Required variable \'${var}\' is blank, enter a value: " new; do
                case "${input:-}" in
                    "") echo -e " > invalid input <"; return 1; ;;
                    *) return 0; ;;
                esac
            done

            if [[ -n "$new" ]]; then new="$(_sanitize_input "$new")"
            elif [[ -n "$cur" ]]; then new="$cur"
            fi
            if [[ -n "$new" ]]; then declare "$var=$new"; _log STEP "Set ${var}=${new}"; fi
        fi
    done

    if _confirm_no "Do you want to manually edit any configuration values?"; then
        _log STEP "Press ENTER to keep the current value in brackets."
        local var cur new updated=0
        _log STEP "Prompting for ${#csm_var_prompt[@]} variables..."
        for var in "${csm_var_prompt[@]}"; do
            # Get current value from the CSM_* variable
            cur="${!var}"
            read -r -p "    Current value for ${cyn}${var}${rst} [${ylw}${cur}${rst}]: " new
            if [[ -n "$new" ]]; then
                new="$(_sanitize_input "$new")"
                # Update the CSM_* variable
                declare "$var=$new"
                _log STEP "Set ${var}=${new}"
                updated=$((updated + 1))
            fi
        done
        _log STEP "Updated ${updated} values"
    fi

    # Write all CSM_* variables to ${CSM_CONF_FILE}
    : > "$user_conf"
    for var in "${csm_var_order[@]}"; do
        echo "${var}=${!var}" >> "$user_conf"
    done
    echo
}

# =============================================================================
# PLATFORM DETECTION
# =============================================================================

_detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then pkg_mgr="apt-get"
    elif command -v dnf     >/dev/null 2>&1; then pkg_mgr="dnf"
    elif command -v yum     >/dev/null 2>&1; then pkg_mgr="yum"
    elif command -v pacman  >/dev/null 2>&1; then pkg_mgr="pacman"
    elif command -v slackpkg >/dev/null 2>&1; then pkg_mgr="slackpkg"
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
        slackpkg)
            _log STEP "_install_pkg: running slackpkg update"
            $var_sudo slackpkg update
            _log STEP "_install_pkg: running slackpkg install $*"
            $var_sudo slackpkg install "$@" ;;
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

_detect_group() {
    curr_runtime="$1"
    case $os_type in
        Darwin|*BSD)
            if dscl . -read /Groups/"$curr_runtime" >/dev/null 2>&1; then
                CSM_GID=$(dscl . -read /Groups/"$curr_runtime" PrimaryGroupID 2>/dev/null | awk '{print $2}')
            fi
            ;;
        Linux)
            if getent group "$curr_runtime" >/dev/null 2>&1; then
                CSM_GID=$(getent group "$curr_runtime" | cut -d: -f3)
            fi
            ;;
    esac
}

_detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        _log PASS "Docker found: $(docker --version)"
        csm_runtime="docker"
        csm_group="docker"
        _detect_group "$csm_group"
        _log STEP "_detect_runtime: docker detected (GID: $CSM_GID)"
        return 0
    elif command -v podman >/dev/null 2>&1; then
        _log PASS "Podman found: $(podman --version)"
        csm_runtime="podman"
        csm_group="podman"
        _detect_group "$csm_group"
        _log STEP "_detect_runtime: podman detected (GID: $CSM_GID)"
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
        _log STEP "Container runtime already installed."
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
    elif [[ -f /etc/rc.d/rc.functions ]]; then
        # Slackware init (used in Unraid)
        init_type="slackware"
    elif [[ -f /etc/init.d/skeleton ]] || [[ -d /etc/init.d ]]; then
        # Traditional SysVinit
        init_type="sysvinit"
    fi

    # 2. Define Internal Helper for status/start
    # Usage: _srvc_manager <service_name> <action: status|start>
    _srvc_manager() {
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
            slackware)
                [[ "$action" == "status" ]] && /etc/rc.d/rc."$srv" status >/dev/null 2>&1 && return 0
                [[ "$action" == "start" ]] && $var_sudo /etc/rc.d/rc."$srv" start && return 0
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
            if _srvc_manager docker status; then
                _log PASS "Docker service is running."
                return 0
            fi

            _log WARN "Docker service is not running."
            if _confirm_yes "Start Docker now?"; then
                _srvc_manager docker start \
                    && _log PASS "Docker started." \
                    || _die "Failed to start Docker. Check logs in /var/log/."
            fi
            ;;
        podman)
            # Podman socket logic varies wildly outside systemd
            if [[ "$init_type" == "systemd" ]]; then
                _log STEP "Checking Podman socket (systemd)..."
                if _srvc_manager podman.socket status; then
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
    _log STEP "_create_group: checking if group '$csm_group' (GID ${csm_gid}) exists..."

    if [[ -z "${csm_gid}" ]]; then
        _log ERROR "Group ID not set, please set 'csm_id' variable and rerun installer."
    fi

    if [[ "$dry_run" == 1 ]]; then
        _log INFO "Would create group '$csm_group' with GID $csm_gid"
    else
        case $os_type in
            Darwin|*BSD)
                if ! dscl . -read /Groups/"$csm_group" >/dev/null 2>&1; then
                    $var_sudo dscl . -create /Groups/"$csm_group" \
                        && $var_sudo dscl . -create /Groups/"$csm_group" PrimaryGroupID "$csm_gid" \
                        && _log INFO "Created group '$csm_group' (GID $csm_gid)" \
                        || _die "Failed to create group '$csm_group'"
                else
                    _log INFO "Group '$csm_group' (GID $csm_gid) already exists."
                fi
                csm_gid=$(dscl . -read /Groups/"$csm_group" PrimaryGroupID 2>/dev/null | awk '{print $2}')
                ;;
            Linux)
                if ! getent group "$csm_group" >/dev/null 2>&1; then
                    $var_sudo groupadd -g "$csm_gid" "$csm_group" \
                        && _log INFO "Created group '$csm_group' (GID $csm_gid)" \
                        || _die "Failed to create group '$csm_group'"
                else
                    _log STEP "Group '$csm_group' (GID $csm_gid) already exists."
                fi
                csm_gid="$(getent group "$csm_group" | cut -d: -f3)"
                ;;
            *) _die "Unsupported OS: $os_type" ;;
        esac
    fi
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
                _log INFO "User added to $csm_group group. Log out and back in for this to take effect."
            fi
        }
    else
        _log PASS "User '$current_user' (UID: $csm_uid) is in the '$csm_group' group."
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
            _log STEP "Created: $tgt"
        fi
    fi
}

_install_file() {
    local src="${1:-}" dest="${2:-}" mode="${3:-}" flag="${4:-}"
    local filename=$(basename "$src")
    if [[ "${force_install}" == 1 ]]; then flag="--force"; fi

    if [[ "$dry_run" == 1 ]]; then
        _log INFO "Would create directory '$tgt' (mode=$mode)"
    else
        if [[ -f "$src" ]]; then
            _log STEP "_install_file: installing $filename (mode=$mode)"
            case "$flag" in
                -f | --force)
                    # Overwrite target file, "-p" (preserve timestamps)
                    $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -p "$src" "$dest/"
                    ;;
                *)
                    # Only copy if changed, "-C"
                    $var_sudo install -o "$csm_uid" -g "$csm_gid" -m "$mode" -C "$src" "$dest/"
            esac
            _log STEP "Installed: $filename → $dest"
        else
            _log WARN "Source file missing: $src"
        fi
    fi
}

_setup_folders() {
    _log STEP "_setup_folders: initializing directory structure at ${CSM_DIR}"

    for dir in "${dirs_list[@]}"; do
        _install_dir "$dir" "$mode_exec"
    done

    # Set secrets directory to more restrictive permissions
    if [[ -d "$CSM_SECRETS" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would set secrets directory to mode 700"
        else
            $var_sudo chmod $mode_auth "$CSM_SECRETS"
        fi
    fi
}

_setup_files() {
    _log STEP "_setup_files: installing required files in ${csm_configs}"

    for file in "${file_list[@]}"; do
        # Set appropriate permissions based on file type
        if [[ "$file" == "${CSM_CORE_FILE}" ]]; then
            file_mode="$mode_exec"
        else
            file_mode="$mode_conf"
        fi
        src_file="${script_path}/${file}"
        if [[ ! -f "$src_file" ]]; then src_file="/dev/null"; fi
        _install_file "$src_file" "${csm_configs}" "$file_mode"
    done

    # Ensure user.conf exists with current values
    local user_conf="${csm_configs}/user.conf"
    if [[ ! -f "$user_conf" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create user.conf in ${csm_configs}"
        else
            _log STEP "Creating user.conf with current values"
            for var in "${csm_var_order[@]}"; do
                echo "${var}=${!var}" >> "$user_conf"
            done
            chown "${csm_uid}:${csm_gid}" "$user_conf"
            chmod "$mode_conf" "$user_conf"
            _log STEP "Created user.conf with current values"
        fi
    fi
}

_setup_network() {
    local net_name="${CSM_NET_NAME:-csm_network}"
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
    _log STEP "Network '$net_name' does not exist"
    # Check if Swarm is active to determine network driver
    if [[ $(_detect_swarm) ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create Docker Swarm overlay network '$net_name'"
        else
            _log STEP "_setup_network: creating docker swarm overlay network $net_name"
            $var_sudo docker network create --driver overlay --attachable "$net_name" >/dev/null 2>&1 \
                && _log PASS "Docker Swarm overlay network '$net_name' created." \
                || _log WARN "Failed to create Docker Swarm network '$net_name'."
        fi
    else
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would create bridge network '$net_name'"
        else
            _log STEP "_setup_network: creating bridge network $net_name"
            $var_sudo $csm_runtime network create "$net_name" >/dev/null 2>&1 \
                && _log PASS "Bridge network '$net_name' created." \
                || _log WARN "Failed to create bridge network '$net_name'."
        fi
    fi
}

# =============================================================================
# SYMLINKS
# =============================================================================

_setup_symlinks() {
    _log STEP "_setup_symlinks: checking and creating symlinks"
    local links=(
        "${HOME}/stacks:${csm_dir}"
        "/usr/local/bin/csm:${csm_configs}/${CSM_CORE_FILE}"
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
                    _log STEP "Corrected symlink: $source"
                fi
            fi
        elif [[ ! -e "$source" ]]; then
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would create symlink: $source -> $target"
            else
                [[ "$source" == /usr/local/bin/* ]] && $var_sudo ln -sf "$target" "$source" || ln -sf "$target" "$source"
                _log STEP "Created symlink: $source"
            fi
        fi
    done
}

_verify_ownership() {
    _log STEP "_verify_ownership: checking current ownership of ${csm_dir}..."
    local current_group current_perms owner

    read -r owner current_group <<< "$(_get_file_info "$csm_dir")"
    _log STEP "Current group: $current_group, target: $csm_group"

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

    _log STEP "Current perms: $(_get_perms "$csm_dir")"
}

# =============================================================================
# UNINSTALL
# =============================================================================

_uninstall_csm() {
    _log WARN "Starting CSM ${red}un${ylw}installation..."
    _log WARN "This will remove the core script and symlinks."
    if [[ "$force_uninstall" == 0 ]]; then
        _log INFO "Your stacks, ${CSM_CONF_FILE}, and templates will NOT be modified."
    else
        _log INFO "Your stacks will not be touched, but ${CSM_CONF_FILE} and templates, will be removed."
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
        _log STEP "Binary symlink $bin_link does not exist"
    fi

    if [[ -L "$csm_link" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove home symlink: $csm_link"
        else
            _log STEP "Removing home directory symlink: $csm_link"
            rm -f "$csm_link"
        fi
    else
        _log STEP "Home symlink $csm_link does not exist"
    fi

    # Remove Core Engine Files
    if [[ -f "${csm_configs}/${CSM_CORE_FILE}" ]]; then
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would remove: ${csm_configs}/${CSM_CORE_FILE}"
        else
            _log STEP "Removing core script: ${csm_configs}/${CSM_CORE_FILE}"
            $var_sudo rm -f "${csm_configs}/${CSM_CORE_FILE}"
        fi
    else
        _log STEP "File ${csm_configs}/${CSM_CORE_FILE} does not exist"
    fi

    # Remove user config and templates if force mode
    if [[ "$force_install" == 1 ]]; then
        _log WARN "Force mode: Removing user config and templates."
        # Remove config files
        for file in "${file_list[@]}"; do
            filename="${csm_configs}/${file}"
            if [[ -f "$filename" ]]; then
                if [[ "$dry_run" == 1 ]]; then
                    _log INFO "Would remove: $filename"
                else
                    _log STEP "Removing: $filename"
                    $var_sudo rm -f "$filename"
                fi
            fi
        done
        # Remove user config
        user_conf="${csm_configs}/${CSM_CONF_FILE}"
        if [[ -f "$user_conf" ]]; then
            if [[ "$dry_run" == 1 ]]; then
                _log INFO "Would remove: $user_conf"
            else
                _log STEP "Removing: $user_conf"
                $var_sudo rm -f "$user_conf"
            fi
        fi
    fi

    if [[ "$dry_run" != 1 ]]; then
        _log PASS "CSM core files and symlinks have been removed."
        _log INFO "DRY-RUN: The container runtime, groups, and ${csm_dir} directories remain intact."
    fi
    exit 0
}

_install_csm() {
    _log INFO "Container Stack Manager v${CSM_VERSION} - installer starting"
    if [[ "$force_install" == 1 ]]; then
        _log WARN "FORCE MODE ACTIVE: Existing configs will be overwritten and prompts bypassed."
    fi

    _detect_pkg_manager
    _user_input
    _create_group
    _install_runtime
    _check_service
    _setup_network
    _setup_folders
    _setup_files
    _setup_symlinks
    _verify_ownership
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) Installer v${CSM_VERSION}${rst}

${bld}Usage:${rst} ${script_path}/${script_file} [options]

${bld}Options:${rst}
    -b | --debug        Enable debug output.
    -d | --dry-run      Dry run mode: show what would be done without making changes.
    -f | --force        Overwrite script and config files without confirmation.
    -h | --help         Show this help message.
    -u | --uninstall    Uninstall all CSM scripts and unmodified config files.
    -V | --version      Show installer version.

${bld}Examples:${rst}
    ${script_path}/${script_file} -f          # Force install, skip prompts
    ${script_path}/${script_file} -d          # Dry run to see what would happen
    ${script_path}/${script_file} -fdx        # Force install, dry-run, debug
    ${script_path}/${script_file} --uninstall # Uninstall CSM

${bld}Container Stack Manager Installer version:${rst} ${ylw}${CSM_VERSION}${rst}
EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Create lockfile after parsing args (skip for dry-run)
    if [[ "$dry_run" != "1" ]]; then
        LOCKDIR="${LOCKDIR:-/var/lock}"
        # Fallback to writable location if /var/lock isn't usable
        if [[ ! -d "$LOCKDIR" || ! -w "$LOCKDIR" ]]; then
            LOCKDIR="/tmp/lock"
        fi
        LOCKFILE="$LOCKDIR/csm-install.lock"
        if [[ ! -d "$LOCKDIR" ]]; then
            mkdir -p "$LOCKDIR" 2>/dev/null || \
            { echo "Cannot create lock dir: $LOCKDIR" >&2; exit 1; }
        fi
        exec 200>"$LOCKFILE" || \
            { echo "Cannot open lockfile: $LOCKFILE" >&2; exit 1; }
        if ! flock -n 200; then
            echo "Another instance of the CSM Installer is already running." >&2
            exit 1
        fi
    fi

    _color_setup
    _detect_os

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
    _detect_runtime || true
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
        _log INFO "  1. Edit user.conf      : csm cfg edit"
        _log INFO "  2. View your stacks    : csm list"
        _log INFO "  3. Show commands list  : csm --help"
        # Check if the invoking user is in the container group (for logout reminder)
        local check_user="${SUDO_USER:-$USER}"
        if ! groups "$check_user" 2>/dev/null | grep -qw "$csm_group"; then
            echo
            _log WARN "Remember to log out and back in so your $csm_group group membership takes effect."
        fi
    fi
    trap 'flock -u 200; exec 200>&-; exit' EXIT
}

main "$@"
