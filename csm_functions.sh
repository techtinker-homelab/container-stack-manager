#!/bin/bash
# Container Stack Manager - Core Functions and Stack Operations
# Combined from core.sh and stack.sh

# Set secure umask (007: rwxrwx--- for dirs, rw-rw---- for files)
umask 0007

# ============================================
# 1. CORE UTILITIES AND CONFIGURATION
# ============================================

# Define color codes
declare -xr RED; RED="$(printf '\033[38;2;255;000;000m')"
declare -xr ORN; ORN="$(printf '\033[38;2;255;075;075m')"
declare -xr YLW; YLW="$(printf '\033[38;2;255;255;000m')"
declare -xr GRN; GRN="$(printf '\033[38;2;000;170;000m')"
declare -xr CYN; CYN="$(printf '\033[38;2;085;255;255m')"
declare -xr BLU; BLU="$(printf '\033[38;2;000;120;255m')"
declare -xr PRP; PRP="$(printf '\033[38;2;085;085;255m')"
declare -xr MGN; MGN="$(printf '\033[38;2;255;085;255m')"
declare -xr WHT; WHT="$(printf '\033[38;2;255;255;255m')"
declare -xr BLK; BLK="$(printf '\033[38;2;025;025;025m')"
declare -xr ULN; ULN="$(printf '\033[4m')"
declare -xr BLD; BLD="$(printf '\033[1m')"
declare -xr DEF; DEF="$(printf '\033[m')"

# Error handling
handle_error() {
    local exit_code
    exit_code=$?
    local cmd
    cmd="$(caller)"
    msg_error "Error in ${cmd}: exit code $exit_code"
    exit $exit_code
}

# Logging functions
declare -A LOG_LEVELS=(
    [ERROR]=1
    [WARN]=2
    [INFO]=3
    [DEBUG]=4
    [SUCCESS]=5
)

log_level=${LOG_LEVELS[INFO]}

# Message functions
msg_alert(){ echo -e "${ORN:?} ALERT ${DEF:?}>> ${BLU:?}${1:-HERE_BE_DRAGONS}${DEF:?} >> ${MGN:?}${2:-this_action_is_final}${DEF:?}\n"; return; }
msg_error(){ echo -e "${RED:?} ERROR ${DEF:?}>> ${BLU:?}${1:-INVALID_ENTRY}${DEF:?} >> ${MGN:?}${2:-please_notify_the_script_author}${DEF:?}\n"; return; }
msg_debug(){ echo -e "${CYN:?} DEBUG ${DEF:?}>> ${BLU:?}${1:-ACTION_IN_PROGRESS}${DEF:?} >> ${MGN:?}${2:-something_is_not_quite_right}${DEF:?}\n"; return; }
msg_failure(){ echo -e "${RED:?} FAILURE ${DEF:?}>> ${BLU:?}${1:-OPERATION_FAILURE}${DEF:?} >> ${MGN:?}${2:-operation_failed}${DEF:?}\n"; return; }
msg_success(){ echo -e "${GRN:?} SUCCESS ${DEF:?}>> ${BLU:?}${1:-OPERATION_SUCCESS}${DEF:?} >> ${MGN:?}${2:-operation_succeeded}${DEF:?}\n"; return; }
msg_warning(){ echo -e "${YLW:?} WARNING ${DEF:?}>> ${BLU:?}${1:-INVALID_ENTRY}${DEF:?} >> ${MGN:?}${2:-please_check_valid_option_flags}${DEF:?}\n"; return; }

log() {
    local level="$1"
    local message="$2"
    local msg_func

    case "$level" in
        ALERT) msg_func=msg_alert ;;
        ERROR) msg_func=msg_error ;;
        WARN) msg_func=msg_warning ;;
        INFO) msg_func=msg_debug ;;
        DEBUG) msg_func=msg_debug ;;
        SUCCESS) msg_func=msg_success ;;
        *) msg_func=msg_debug ;;
    esac

    if [[ ${LOG_LEVELS[$level]} -le $log_level ]]; then
        $msg_func "$message"
    fi
}

# ============================================
# 1. FILE AND DIRECTORY MANAGEMENT
# ============================================

# Permission modes
readonly DIR_MODE=0770          # rwxrwx--- (default directory permissions)
readonly DIR_RESTRICTED_MODE=0750  # rwxr-x--- (restricted directory permissions)
readonly FILE_MODE=0660          # rw-rw---- (default file permissions)
readonly FILE_RESTRICTED_MODE=0600  # rw------- (restricted file permissions)

# Files that require restrictive permissions (0600: rw-------)
# These are typically certificate and key files that need extra protection
readonly FILES_RESTRICTED_LIST=(
    # Certificate and key files
    "*.pem"        # SSL certificates and keys
    "*.key"        # Private keys
    "*.crt"        # SSL certificates
    "*.p12"        # PKCS#12 certificate bundles
    "*.pfx"        # PKCS#12 certificate bundles (Windows)
    "*.jks"        # Java KeyStore files
    "*.cer"        # Alternative certificate format
    "*.csr"        # Certificate Signing Requests
    "*.p8"         # PKCS#8 private keys
    "*.der"        # Binary certificate format

    # Authentication files
    "*.htpasswd"   # Authentication files
    "*_rsa"        # SSH private keys
    "*_dsa"        # SSH private keys
    "*_ed25519"    # SSH private keys
    "*_ecdsa"      # SSH private keys
    "known_hosts"  # SSH known hosts
    "authorized_keys" # SSH authorized keys
)

# Other files that need to be tracked (0660: rw-rw----)
# readonly FILES_LIST=(
#     # Configuration files
#     "*.yaml"       # YAML configuration files
#     "*.yml"        # Alternative YAML extension
#     "*.json"       # JSON configuration files
#     "*.conf"       # General configuration files
#     "*.ini"        # INI configuration files
#     "*.cnf"        # Alternative config extension
#     "*.toml"       # TOML configuration files
#     "*.properties" # Java properties files

#     # Environment
#     "*.env"        # Environment files

#     # Database files
#     "*.db"         # Database files
#     "*.sqlite"     # SQLite database
#     "*.sql"        # SQL dump files
#     "*.dump"       # Database dumps

#     # Application specific
#     "*.ovpn"       # OpenVPN configuration
#     "*.kdbx"       # KeePass database
#     "*.sock"       # Unix domain sockets
#     "*.pid"        # Process ID files
# )

# Directories that require special attention (0750: rwxr-x---)
# These directories contain sensitive data but need group access
readonly DIRS_RESTRICTED_LIST=(
    # Certificate and key storage
    "certs"        # SSL certificates
    "certs.d"      # Certificate directory
    "ssl"          # SSL certificates
    "keys"         # Private keys
    "acme"         # Let's Encrypt certificates
    "letsencrypt"  # Let's Encrypt certificates

    # Authentication and security
    "auth"         # Authentication files
    "secrets"      # Secret files
    "ssh"          # SSH configuration and keys
    "gpg"          # GPG configuration and keys
    "gnupg"        # Alternative GPG directory
)

# Other directories that need to be tracked (0770: rwxrwx---)
# readonly DIRS_LIST=(
#     # Configuration directories
#     "config"       # Configuration files
#     "configs"      # Alternative config directory
#     "conf"         # Configuration files
#     "conf.d"       # Configuration directory
#     "config.d"     # Configuration directory
#     "etc"          # System configuration

#     # Data and state
#     "data"         # Application data
#     "db"           # Database directory
#     "database"     # Alternative database directory
#     "state"        # State information
#     "run"          # Runtime data
#     "tmp"          # Temporary files

#     # Backup and migration
#     "backups"      # Backup files
#     "archive"      # Archived files
#     "migrations"   # Database migrations

#     # Application specific
#     "templates"    # Template files
#     "cache"        # Cache directory
#     "logs"         # Log files
#     "sessions"     # Session data
# )

# Check if sudo is needed
if [[ $(id -u) -ne 0 ]] && [[ -e $(command -v sudo) ]]; then
    readonly var_sudo="sudo"
else
    readonly var_sudo=""
fi

# Helper function to check if permissions need to be updated
needs_permission_update() {
    local path="$1"
    local expected_mode="$2"
    local expected_owner="$3"
    local expected_group="$4"

    # Get current permissions and ownership
    local current_mode
    local current_owner
    local current_group

    # Use stat to get current mode in octal
    if [[ -e "$path" ]]; then
        if [[ $(uname) == "Darwin" ]]; then
            # macOS stat
            current_mode=$(stat -f '%Lp' "$path")
            current_owner=$(stat -f '%Su' "$path")
            current_group=$(stat -f '%Sg' "$path")
        else
            # Linux stat
            current_mode=$(stat -c '%a' "$path")
            current_owner=$(stat -c '%U' "$path")
            current_group=$(stat -c '%G' "$path")
        fi

        # Convert to octal if it's not already
        if [[ ! "$current_mode" =~ ^[0-7]{3,4}$ ]]; then
            current_mode=$(printf "%o" "0$current_mode")
        fi

        # Remove leading zeros for comparison
        current_mode=$((10#$current_mode))
        expected_mode=$((10#$expected_mode))

        # Check if any attribute needs updating
        if [[ "$current_mode" -ne "$expected_mode" ||
              "$current_owner" != "$expected_owner" ||
              "$current_group" != "$expected_group" ]]; then
            return 0  # Needs update
        fi
        return 1  # No update needed
    fi
    return 0  # Path doesn't exist, needs creation
}

# Helper function to install files/directories with proper permissions
install_secure() {
    local src="$1"
    local tgt="$2"
    local mode="${3:-$FILE_MODE}"
    local create="${4:-false}"
    local owner="${5:-$CSM_OWNER}"
    local group="${6:-$CSM_GROUP}"
    local old_umask

    # Store current umask and set secure umask
    old_umask=$(umask)
    umask 0007

    if [[ "$create" == "true" ]]; then
        if [[ ! -d "$tgt" ]]; then
            if ! needs_permission_update "$tgt" "${mode:-$DIR_MODE}" "$owner" "$group"; then
                log DEBUG "Directory already exists with correct permissions: $tgt"
                umask "$old_umask"
                return 0
            fi

            if ! ${var_sudo} install -o "$owner" -g "$group" -m "${mode:-$DIR_MODE}" -d "$tgt"; then
                log ERROR "Failed to create directory: $tgt"
                umask "$old_umask"
                return 1
            fi
            log INFO "Created directory: $tgt (mode: ${mode:-$DIR_MODE}, owner: $owner:$group)"
        else
            # Directory exists, check if permissions need updating
            if needs_permission_update "$tgt" "${mode:-$DIR_MODE}" "$owner" "$group"; then
                if ! ${var_sudo} chmod "${mode:-$DIR_MODE}" "$tgt" ||
                   ! ${var_sudo} chown "$owner:$group" "$tgt"; then
                    log ERROR "Failed to update permissions for directory: $tgt"
                    umask "$old_umask"
                    return 1
                fi
                log INFO "Updated directory permissions: $tgt (mode: ${mode:-$DIR_MODE}, owner: $owner:$group)"
            else
                log DEBUG "Directory already has correct permissions: $tgt"
            fi
        fi
    elif [[ -f "$src" ]]; then
        # Create parent directory if it doesn't exist
        local parent_dir
        parent_dir=$(dirname "$tgt")
        if [[ ! -d "$parent_dir" ]]; then
            install_secure "" "$parent_dir" "$DIR_MODE" true "$owner" "$group" || {
                umask "$old_umask"
                return 1
            }
        fi

        # Check if target file exists and has correct permissions
        if [[ -e "$tgt" ]]; then
            if ! needs_permission_update "$tgt" "$mode" "$owner" "$group"; then
                log DEBUG "File already exists with correct permissions: $tgt"
                umask "$old_umask"
                return 0
            fi
        fi

        # Install the file
        if ! ${var_sudo} install -o "$owner" -g "$group" -m "$mode" "$src" "$tgt"; then
            log ERROR "Failed to install: $tgt"
            umask "$old_umask"
            return 1
        fi
        log INFO "Installed: $tgt (mode: $mode, owner: $owner:$group)"
    else
        log WARNING "Source file not found: $src"
        umask "$old_umask"
        return 1
    fi

    # Restore original umask
    umask "$old_umask"
    return 0
}

# ============================================
# 2. PERMISSIONS MANAGEMENT
# ============================================

# Function to fix permissions recursively with minimal changes
fix_permissions() {
    local target_dir="${1:-$STACKS_DIR}"
    local sudo_cmd="${var_sudo}"  # Always use var_sudo for consistency
    local old_umask
    local changed=0
    local dry_run=false

    # Parse options
    local args=("$@")
    for i in "${!args[@]}"; do
        if [[ "${args[i]}" == "--dry-run" ]]; then
            dry_run=true
            unset 'args[i]'
        fi
    done
    set -- "${args[@]}"

    # Store current umask and set secure umask
    old_umask=$(umask)
    umask 0007

    if [[ "$dry_run" == true ]]; then
        log ALERT "=== DRY RUN: No changes will be made ==="
    fi

    # Verify target directory exists
    if [[ ! -d "$target_dir" ]]; then
        log ERROR "Target directory does not exist: $target_dir"
        umask "$old_umask"
        return 1
    fi

    log INFO "Checking and fixing permissions for: $target_dir"

    # Update directory permissions (only if needed)
    log INFO "Checking directory permissions..."
    while IFS= read -r dir; do
        local dir_name
        dir_name="$(basename "$dir")"
        local dir_mode=$DIR_MODE  # Default directory mode

        # Check if this is a restricted directory
        local is_restricted=false
        for pattern in "${DIRS_RESTRICTED_LIST[@]}"; do
            if [[ "$dir_name" == "$pattern" || "$dir_name" == "$pattern/"* ]]; then
                is_restricted=true
                break
            fi
        done

        # Set mode based on directory type
        if [[ "$is_restricted" == true ]]; then
            dir_mode=$DIR_RESTRICTED_MODE
        fi

        if needs_permission_update "$dir" "$dir_mode" "$STACKS_UID" "$STACKS_GID"; then
            if [[ "$dry_run" == true ]]; then
                log INFO "[DRY RUN] Would update directory: $dir ($(printf '%04o' $dir_mode), $STACKS_UID:$STACKS_GID)"
                changed=$((changed + 1))
            else
                if ! ${sudo_cmd} chmod "$dir_mode" "$dir" || ! ${sudo_cmd} chown "${STACKS_UID}:${STACKS_GID}" "$dir"; then
                    log WARNING "Failed to update permissions for directory: $dir"
                else
                    log DEBUG "Updated directory permissions: $dir ($(printf '%04o' $dir_mode), $STACKS_UID:$STACKS_GID)"
                    changed=$((changed + 1))
                fi
            fi
        fi
    done < <(${sudo_cmd} find "$target_dir" -type d 2>/dev/null)

    # Update file permissions (only if needed)
    log INFO "Checking file permissions..."
    while IFS= read -r file; do
        local file_name
        file_name="$(basename "$file")"
        local mode=$FILE_MODE  # Default file mode (rw-rw----)

        # Check if this is a restricted file
        for pattern in "${FILES_RESTRICTED_LIST[@]}"; do
            if [[ "$file_name" == "$pattern" ]]; then
                mode=$FILE_RESTRICTED_MODE  # rw------- for restricted files
                break
            fi
        done

        if needs_permission_update "$file" "$mode" "$STACKS_UID" "$STACKS_GID"; then
            if [[ "$dry_run" == true ]]; then
                log INFO "[DRY RUN] Would update file: $file ($mode, $STACKS_UID:$STACKS_GID)"
                changed=$((changed + 1))
            else
                if ! ${sudo_cmd} chmod "$mode" "$file" || ! ${sudo_cmd} chown "${STACKS_UID}:${STACKS_GID}" "$file"; then
                    log WARNING "Failed to update permissions for file: $file"
                else
                    log DEBUG "Updated file permissions: $file ($mode, $STACKS_UID:$STACKS_GID)"
                    changed=$((changed + 1))
                fi
            fi
        fi
    done < <(${sudo_cmd} find "$target_dir" -type f 2>/dev/null)

    # Special handling for sensitive directories
    log INFO "Checking sensitive directories..."
    for dir in "${SPECIAL_DIRS[@]}"; do
        while IFS= read -r sensitive_dir; do
            if needs_permission_update "$sensitive_dir" "0750" "$STACKS_UID" "$STACKS_GID"; then
                if [[ "$dry_run" == true ]]; then
                    log INFO "[DRY RUN] Would update sensitive directory: $sensitive_dir (0750, $STACKS_UID:$STACKS_GID)"
                    changed=$((changed + 1))
                else
                    if ! ${sudo_cmd} chmod 0750 "$sensitive_dir" || ! ${sudo_cmd} chown "${STACKS_UID}:${STACKS_GID}" "$sensitive_dir"; then
                        log WARNING "Failed to update permissions for sensitive directory: $sensitive_dir"
                    else
                        log DEBUG "Updated sensitive directory permissions: $sensitive_dir (0750, $STACKS_UID:$STACKS_GID)"
                        changed=$((changed + 1))
                    fi
                fi
            fi
        done < <(${sudo_cmd} find "$target_dir" -type d -name "$dir" 2>/dev/null)
    done

    # Final verification
    local bad_perms=0
    while IFS= read -r path; do
        if [[ -d "$path" ]]; then
            if needs_permission_update "$path" "0770" "$STACKS_UID" "$STACKS_GID"; then
                bad_perms=$((bad_perms + 1))
            fi
        else
            # Check if it's a special file
            local mode=0660
            for pattern in "${SPECIAL_FILES[@]}"; do
                if [[ "$(basename "$path")" == "$pattern" ]]; then
                    mode=0640
                    break
                fi
            done

            if needs_permission_update "$path" "$mode" "$STACKS_UID" "$STACKS_GID"; then
                bad_perms=$((bad_perms + 1))
            fi
        fi
    done < <(${sudo_cmd} find "$target_dir" 2>/dev/null)

    if [[ "$dry_run" == true ]]; then
        if [[ "$changed" -gt 0 ]]; then
            log INFO "[DRY RUN] Would fix permissions for $changed items (found $bad_perms items that need attention)"
        else
            log INFO "[DRY RUN] No permission changes needed (found $bad_perms items that need attention)"
        fi
    else
        if [[ "$bad_perms" -gt 0 ]]; then
            log WARNING "Found $bad_perms items with incorrect permissions that couldn't be fixed"
        elif [[ "$changed" -gt 0 ]]; then
            log SUCCESS "Fixed permissions for $changed items"
        else
            log SUCCESS "All permissions verified"
        fi
    fi

    # Restore original umask
    umask "$old_umask"

    if [[ "$dry_run" == true ]]; then
        log INFO "=== DRY RUN COMPLETE ==="
    fi

    if [[ "$bad_perms" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ============================================
# 3. CONFIGURATION MANAGEMENT
# ============================================

# Default configuration values
declare -A CONFIG_DEFAULTS=(
    [container_runtime]="podman"
    [CSM_ROOT]="/srv/csm"
    [BACKUP_DIR]="${CSM_ROOT}/backup"
    [COMMON_DIR]="${CSM_ROOT}/common"
    [STACKS_DIR]="${CSM_ROOT}/stacks"
    [CONFIGS_DIR]="${CSM_COMMON}/configs"
    [SECRETS_DIR]="${CSM_COMMON}/secrets"
    [TEMPLATES_DIR]="${CSM_COMMON}/templates"
    [TEMPLATE_BRANCH]="main"
    [TEMPLATE_REPO]="https://www.gitlab.com/techtinker/stack_templates"
    [BACKUP_MAX_AGE]="30"
    [BACKUP_COMPRESSION]="zip"
    [NETWORK_NAME]="csm_network"
    [NETWORK_SUBNET]="172.20.0.0/16"
    [VOLUME_DRIVER]="local"
    [VOLUME_LABEL]="csm.volume"
    [UPDATE_CHECK_INTERVAL]="7"
    [UPDATE_SOURCE]="github"
    [UPDATE_BRANCH]="main"
)

# Load configuration from files and environment
load_config() {
    local config_files=(
        "${CSM_ROOT}/csm.conf"
        "/etc/csm/csm.conf"
        "${HOME}/.config/csm/config"
        "${PWD}/.csm/config"
    )

    # Set default values first
    for key in "${!CONFIG_DEFAULTS[@]}"; do
        export "$key"="${CONFIG_DEFAULTS[$key]}"
    done

    # Load from files in order of increasing precedence
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            log DEBUG "Loading config from $file"
            # shellcheck source=/dev/null
            source "$file"
        fi
    done

    # Apply environment variable overrides (CSM_*)
    while IFS='=' read -r -d '' key value; do
        if [[ "$key" == CSM_* ]]; then
            local config_key="${key#CSM_}"
            if [[ -n "${CONFIG_DEFAULTS[$config_key]+x}" ]]; then
                export "$config_key"="$value"
            else
                log WARN "Unknown config key in environment: $key"
            fi
        fi
    done < <(env -0 2>/dev/null || env)

    # Ensure dependent paths are set correctly by comparing to user/project/base configs in that order
    if [[ -r "${HOME}/.config/csm/config" ]]; then
        log DEBUG "Loading config from ${HOME}/.config/csm/config"
        # shellcheck source=/dev/null
        source "${HOME}/.config/csm/config"
    elif [[ -r "${CSM_ROOT}/common/user.conf" ]]; then
        log DEBUG "Loading config from ${CSM_ROOT}/common/user.conf"
        # shellcheck source=/dev/null
        source "${CSM_ROOT}/common/user.conf"
    elif [[ -r "${PWD}/.csm/config" ]]; then
        log DEBUG "Loading config from ${PWD}/.csm/config"
        # shellcheck source=/dev/null
        source "${PWD}/.csm/config"
    elif [[ -r "${CSM_ROOT}/common/default.conf" ]]; then
        log DEBUG "Loading config from ${CSM_ROOT}/common/default.conf"
        # shellcheck source=/dev/null
        source "${CSM_ROOT}/common/default.conf"
    elif [[ -r "/etc/csm/csm.conf" ]]; then
        log DEBUG "Loading config from /etc/csm/csm.conf"
        # shellcheck source=/dev/null
        source "/etc/csm/csm.conf"
    else
        log ERROR "No configuration file found in:\n${CSM_ROOT}/common\n${HOME}/.config/csm\n${PWD}/.csm\n/etc/csm"
        exit 1
    fi
}

# Validate the current configuration
validate_config() {
    local errors=0

    # Check required directories
    local required_dirs=(
        "$CSM_ROOT"
        "$CSM_BACKUP"
        "$CSM_COMMON"
        "$CSM_STACKS"
        "$CSM_CONFIGS"
        "$CSM_SECRETS"
        "$CSM_TEMPLATES"
    )

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log DEBUG "Creating directory: $dir"
            mkdir -p "$dir" || {
                log ERROR "Failed to create directory: $dir"
                ((errors++))
                continue
            }
            fix_permissions "$dir"
        fi
    done

    # Validate container runtime
    if ! command -v "$container_runtime" &>/dev/null; then
        log ERROR "Container runtime not found: $container_runtime"
        ((errors++))
    fi

    return $errors
}

# Get a configuration value
get_config() {
    local key="$1"
    local default_value="${2:-}"

    # Check if the key exists in environment
    if [[ -n "${!key+x}" ]]; then
        echo "${!key}"
    # Check if it's a known config with a default
    elif [[ -n "${CONFIG_DEFAULTS[$key]+x}" ]]; then
        echo "${CONFIG_DEFAULTS[$key]}"
    else
        echo "$default_value"
    fi
}

# Set a configuration value
set_config() {
    local key="$1"
    local value="$2"
    local config_file="${3:-${CONFIG_DIR}/csm.conf}"

    # Create config directory if it doesn't exist
    mkdir -p "$(dirname "$config_file")" || {
        log ERROR "Failed to create config directory: $(dirname "$config_file")"
        return 1
    }

    # Update the value in the environment
    export "$key"="$value"

    # Update the config file
    if grep -q "^$key=" "$config_file" 2>/dev/null; then
        # Update existing key
        if sed -i '' "s|^$key=.*|$key=$value|" "$config_file" 2>/dev/null ||
           sed -i "s|^$key=.*|$key=$value|" "$config_file" 2>/dev/null; then
            log DEBUG "Updated config: $key=$value in $config_file"
        else
            log ERROR "Failed to update config: $key in $config_file"
            return 1
        fi
    else
        # Add new key
        echo "$key=$value" >> "$config_file" || {
            log ERROR "Failed to write to config file: $config_file"
            return 1
        }
        log DEBUG "Added config: $key=$value to $config_file"
    fi

    return 0
}

# Edit configuration file
edit_config() {
    local config_file="${1:-${CONFIG_DIR}/csm.conf}"
    local editor="${EDITOR:-vi}"

    # Create default config if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        mkdir -p "$(dirname "$config_file")"
        for key in "${!CONFIG_DEFAULTS[@]}"; do
            echo "$key=${CONFIG_DEFAULTS[$key]}" >> "$config_file"
        done
    fi

    # Open the editor
    if ! "$editor" "$config_file"; then
        log ERROR "Failed to open editor: $editor"
        return 1
    fi

    # Reload configuration
    load_config
    validate_config
}

# Initialize configuration
load_config
if ! validate_config; then
    log WARN "Configuration validation completed with warnings"
fi

# ============================================
# 4. CONTAINER RUNTIME AND COMMAND DETECTION
# ============================================

detect_runtime() {
    container_runtime=""

    if command -v podman &>/dev/null; then
        container_runtime="podman"
    elif command -v docker &>/dev/null; then
        container_runtime="docker"
    else
        log ERROR "No supported container runtime found, please install podman or docker"
        return 1
    fi
    log INFO "Detected container runtime: $container_runtime"
    export container_runtime
}

detect_compose_command() {
    # Try to detect container runtime
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        RUNTIME="podman"
    else
        log ERROR "No supported container runtime found. Please install Docker or Podman."
        return 1
    fi

    # Detect compose command based on runtime
    case "$RUNTIME" in
        docker)
            # Try docker compose (newer plugin format)
            if docker compose version >/dev/null 2>&1; then
                COMPOSE_CMD="docker compose"
                COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)
                log INFO "Using Docker Compose Plugin (v${COMPOSE_VERSION})"
                return 0
            # Try docker-compose (older standalone)
            elif command -v docker-compose >/dev/null 2>&1; then
                COMPOSE_CMD="docker-compose"
                COMPOSE_VERSION=$($COMPOSE_CMD --version | awk '{print $3}' | tr -d ',')
                log INFO "Using Docker Compose Standalone (v${COMPOSE_VERSION})"
                return 0
            fi
            ;;
        podman)
            # Try podman-compose
            if command -v podman-compose >/dev/null 2>&1; then
                COMPOSE_CMD="podman-compose"
                COMPOSE_VERSION=$($COMPOSE_CMD --version | awk '{print $3}' | tr -d ',')
                log INFO "Using Podman Compose (v${COMPOSE_VERSION})"
                return 0
            # Try podman with compose subcommand (Podman 4.0+)
            elif podman compose version >/dev/null 2>&1; then
                COMPOSE_CMD="podman compose"
                COMPOSE_VERSION=$(podman compose version --short 2>/dev/null)
                log INFO "Using Podman Compose Plugin (v${COMPOSE_VERSION})"
                return 0
            fi
            ;;
    esac

    log ERROR "No working compose command found for $RUNTIME"
    log INFO "For Docker:"
    log INFO "  - Plugin: https://docs.docker.com/compose/install/compose-plugin/"
    log INFO "  - Standalone: https://docs.docker.com/compose/install/linux/"
    log INFO "For Podman:"
    log INFO "  - podman-compose: https://github.com/containers/podman-compose"
    log INFO "  - Podman 4.0+ includes native compose support"
    return 1
}

# ============================================
# 5. STACK DIRECTORY MANAGEMENT
# ============================================

get_stack_dir() {
    local stack_name
    stack_name="$1"
    local mode="$2"
    local stack_dir
    stack_dir="${CSM_ROOT}/stacks/${stack_name}"
    echo "${stack_dir}"
}

ensure_stack_dir() {
    local stack_name="$1"
    local mode="$2"
    local stack_dir
    stack_dir="$(get_stack_dir "$stack_name" "$mode")"

    if [[ ! -d "$stack_dir" ]]; then
        mkdir -p "$stack_dir"
        log INFO "Created stack directory: $stack_dir"
    fi
}

# ============================================
# 6. TEMPLATE MANAGEMENT
# ============================================

# Fetch available templates from remote repository
fetch_remote_templates() {
    local cache_file="/tmp/csm_remote_templates.cache"
    local cache_age=3600  # 1 hour cache
    local response templates

    # Ensure cache directory exists
    local cache_dir
    cache_dir="$(dirname "$cache_file")"
    mkdir -p "$cache_dir"

    # Check if we have a recent cache
    if [[ -f "$cache_file" ]]; then
        local cache_mtime
        if cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null); then
            if (( $(date +%s) - cache_mtime < cache_age )); then
                if [[ -s "$cache_file" ]]; then
                    cat "$cache_file"
                    return 0
                fi
            fi
        fi
    fi

    # Fetch from remote repository
    local repo_url
    repo_url="${TEMPLATE_REPO%.git}"
    local api_url
    api_url="${repo_url}/-/tree/${TEMPLATE_BRANCH}?format=json"

    if ! response=$(curl -sL --max-time 10 --connect-timeout 5 "$api_url" 2>/dev/null) || [[ -z "$response" ]]; then
        log WARN "Failed to fetch remote templates from $api_url"
        # Return cached version if available, even if expired
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi
        return 1
    fi

    # Extract template names (subdirectories)
    if ! templates=$(echo "$response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | grep -v '^[.]' | sort); then
        log WARN "Failed to parse template list from remote repository"
        return 1
    fi

    if [[ -z "$templates" ]]; then
        log WARN "No templates found in remote repository"
        return 1
    fi

    # Cache the result
    echo "$templates" > "$cache_file" || {
        log WARN "Failed to cache remote templates"
        # Continue even if cache fails
    }

    echo "$templates"
}

# Ensure templates directory exists
ensure_templates_dir() {
    if [[ ! -d "$TEMPLATE_PATH" ]]; then
        mkdir -p "$TEMPLATE_PATH"
        fix_permissions "$TEMPLATE_PATH"
        log INFO "Created templates directory: $TEMPLATE_PATH"
    fi
}

# List available templates (local and remote)
template_list() {
    local local_templates=() remote_templates=()

    # Get local templates (directories in TEMPLATE_PATH)
    if [[ -d "$TEMPLATE_PATH" ]]; then
        while IFS= read -r -d '' template_dir; do
            # Only include directories that contain a compose.yml file
            if [[ -f "${template_dir}/compose.yml" ]]; then
                local_templates+=("$(basename "$template_dir")")
            fi
        done < <(find "$TEMPLATE_PATH" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

        # Sort the templates alphabetically
        # Use version-appropriate method to sort the array
        local sorted_templates=()

        # Check bash version (4.0+ supports mapfile)
        if (( BASH_VERSINFO[0] >= 4 )); then
            # Modern bash (4.0+) - use mapfile
            mapfile -t sorted_templates < <(printf '%s\n' "${local_templates[@]}" | sort)
        else
            # Older bash - use read -a for compatibility
            IFS=$'\n' read -r -d '' -a sorted_templates < <(printf '%s\n' "${local_templates[@]}" | sort && printf '\0')
            unset IFS
        fi

        # Copy the sorted array back
        local_templates=("${sorted_templates[@]}")
    fi

    # Get remote templates if no local ones found
    if [[ ${#local_templates[@]} -eq 0 ]]; then
        log INFO "No local templates found, checking remote repository..."
        while IFS= read -r template; do
            [[ -n "$template" ]] && remote_templates+=("$template")
        done < <(fetch_remote_templates)
    fi

    # Display results
    if [[ ${#local_templates[@]} -gt 0 ]]; then
        log INFO "Available local templates in $TEMPLATE_PATH:"
        for template in "${local_templates[@]}"; do
            echo "- $template"
        done
    elif [[ ${#remote_templates[@]} -gt 0 ]]; then
        log INFO "Available remote templates (use 'csm template add <name>' to download):"
        for template in "${remote_templates[@]}"; do
            echo "- $template"
        done
    else
        log WARN "No templates found locally or remotely"
        return 1
    fi
}

# Add a template from remote or local source
template_add() {
    local template_name
    template_name="$1"
    local source_path
    source_path="$2"
    local template_dir
    template_dir="${TEMPLATE_PATH}"

    if [[ -z "$template_name" ]]; then
        log ERROR "Template name is required"
        return 1
    fi

    # Ensure templates directory exists
    if [[ ! -d "$template_dir" ]]; then
        if ! mkdir -p "$template_dir"; then
            log ERROR "Failed to create templates directory: $template_dir"
            return 1
        fi
        chmod 750 "$template_dir"
    fi

    # If source path is provided, use it
    if [[ -n "$source_path" && -d "$source_path" ]]; then
        log INFO "Installing template from local path: $source_path"

        # Check if template files exist in source path
        if [[ ! -f "${source_path}/compose.yml" ]]; then
            log ERROR "Source directory does not contain a compose.yml file"
            return 1
        fi

        # Copy all files to the templates directory
        find "$source_path" -type f -exec cp -n "{}" "$template_dir/" \;
    else
        # Try to fetch from remote
        log INFO "Downloading template '$template_name' from remote repository..."
        local repo_url="${TEMPLATE_REPO}/-/raw/${TEMPLATE_BRANCH}/${template_name}"
        local temp_dir
        temp_dir="$(mktemp -d)"

        # Download template files
        if ! curl -sL "${repo_url}/compose.yml" -o "${temp_dir}/compose.yml" ||
           ! curl -sL "${repo_url}/README.md" -o "${temp_dir}/README.md" 2>/dev/null; then
            rm -rf "$temp_dir"
            log ERROR "Failed to download template '$template_name'"
            return 1
        fi

        # Move directories and files to templates directory
        find "$temp_dir" -type f -exec mv -n "{}" "$template_dir/" \;
        rmdir "$temp_dir"
    fi

    fix_permissions "$template_dir"
    log SUCCESS "Template '$template_name' added successfully to $template_dir"
}

template_remove() {
    local template_name="$1"
    local template_file="${TEMPLATE_PATH}/${template_name}"
    local confirm

    if [[ -z "$template_name" ]]; then
        log ERROR "Template name is required"
        return 1
    fi

    # Check if template file exists
    if [[ ! -f "$template_file" ]]; then
        log ERROR "Template file '$template_name' not found in $TEMPLATE_PATH"
        return 1
    fi

    read -r -p "Are you sure you want to remove template file '$template_name'? [y/N] " confirm
    echo  # Add a newline after the prompt

    if [[ $confirm =~ ^[Yy]$ ]]; then
        # Normalize paths for comparison
        local normalized_template_file
        normalized_template_file=$(realpath -m "$template_file" 2>/dev/null || echo "$template_file")
        local normalized_templates_dir
        normalized_templates_dir=$(realpath -m "$TEMPLATE_PATH" 2>/dev/null || echo "$TEMPLATE_PATH")

        # Check if the file is within the templates directory
        if [[ ! "$normalized_template_file" == "$normalized_templates_dir/"* ]]; then
            log ERROR "Template file path is not within allowed directory: $normalized_templates_dir"
            return 1
        fi

        # Additional safety checks
        if [[ -z "$normalized_template_file" ||
              "$normalized_template_file" == "/" ||
              "$normalized_template_file" == "$normalized_templates_dir" ]]; then
            log ERROR "Safety check failed, invalid path: $template_file"
            return 1
        fi

        # Check if file exists and is a regular file
        if [[ ! -f "$template_file" ]]; then
            log ERROR "Template file does not exist: $template_file"
            return 1
        fi

        # Remove the template file
        if ! rm -f -- "$template_file"; then
            log ERROR "Failed to remove template file '$template_name'"
            return 1
        fi

        # Also remove any related files (like README.md if it exists)
        local base_name="${template_file%.*}"
        rm -f -- "${base_name}.md" "${base_name}.yaml" "${base_name}.yml" 2>/dev/null || true

        log SUCCESS "Template '$template_name' removed successfully"
        return 0
    else
        log INFO "Template removal cancelled"
        return 0
    fi
}

template_update() {
    local template_name
    template_name="$1"
    local template_dir="${TEMPLATE_PATH}/${template_name}"
    local template_repo_url="${TEMPLATE_REPO}/raw/main/templates/${template_name}"

    if [[ -z "$template_name" ]]; then
        log ERROR "Template name is required"
        return 1
    fi

    # Check if template directory exists
    if [[ ! -d "$template_dir" ]]; then
        log ERROR "Template directory '$template_name' not found in $TEMPLATE_PATH"
        return 1
    fi

    log INFO "Updating template '$template_name'..."

    # Create a temporary directory for the update
    local temp_dir
    temp_dir=$(mktemp -d)

    # Create backup directory if it doesn't exist
    local backup_dir="${TEMPLATE_PATH}/.backup/${template_name}"
    mkdir -p "$backup_dir"

    # Create timestamp for backup
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${backup_dir}/${timestamp}"

    # Create timestamped backup directory
    mkdir -p "$backup_path"

    # Backup existing template files
    if [[ -d "$template_dir" ]]; then
        if ! cp -r "$template_dir/"* "$backup_path/" 2>/dev/null; then
            log WARN "No files to backup in template directory"
        fi
    fi

    # Download the updated template files
    log INFO "Downloading updated template from ${template_repo_url}..."

    # Create a temporary directory for the download
    local download_dir="${temp_dir}/${template_name}"
    mkdir -p "$download_dir"

    # Download common template files
    for file in "compose.yml" "README.md" "config.env.example"; do
        if ! curl -sL "${template_repo_url}/${file}" -o "${download_dir}/${file}" 2>/dev/null; then
            log DEBUG "File ${file} not found in remote template"
            rm -f "${download_dir}/${file}" 2>/dev/null
        fi
    done

    # Check if we got any files
    if ! ls -A "$download_dir"/* >/dev/null 2>&1; then
        log ERROR "No template files found in remote repository"
        rm -rf "$temp_dir"
        return 1
    fi

    # Remove existing template directory and replace with new files
    if ! rm -rf "$template_dir" || ! mv "$download_dir" "$template_dir"; then
        log ERROR "Failed to update template directory"
        rm -rf "$temp_dir"
        return 1
    fi

    # Set correct permissions
    find "$template_dir" -type f -exec chmod 644 {} \;
    find "$template_dir" -type d -exec chmod 755 {} \;

    # Clean up
    rm -rf "$temp_dir"

    log SUCCESS "Template '$template_name' updated successfully (backup in ${backup_path})"
    return 0
}

manage_templates() {
    local action
    action="$1"
    local template_name
    template_name="$2"

    case "$action" in
        add)
            template_add "$template_name"
            ;;
        remove)
            template_remove "$template_name"
            ;;
        update)
            template_update "$template_name"
            ;;
        list)
            template_list
            ;;
        *)
            log ERROR "Invalid action: $action"
            return 1
            ;;
    esac
}

# ============================================
# 7. STACK OPERATIONS
# ============================================

create_stack() {
    local stack_name
    stack_name="$1"

    if [[ -z "$stack_name" ]]; then
        log ERROR "Stack name is required"
        return 1
    fi

    local stack_dir="${CSM_ROOT}/stacks/${stack_name}"
    if [[ -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' already exists"
        return 1
    fi

    log INFO "Creating stack '$stack_name'..."

    # Create stack directory structure
    mkdir -p "${stack_dir}/appdata"

    # Set appropriate permissions
    fix_permissions "$stack_dir"

    # Create basic files
    touch "${stack_dir}/.env"
    cat << EOF > "${stack_dir}/compose.yml"
version: '3.8'
services:
  # Add your services here
networks:
  default:
    external:
      name: ${NETWORK_NAME:-csm_network}
EOF

    log INFO "Stack '$stack_name' created successfully in ${stack_dir}"
}

modify_stack() {
    local stack_name="$1"
    local stack_dir="${CSM_ROOT}/stacks/${stack_name}"

    if [[ -z "$stack_name" ]]; then
        log ERROR "Stack name is required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Opening compose file for stack '$stack_name'..."

    # Use preferred editor or default to nano
    if [[ -n "$EDITOR" ]]; then
        $EDITOR "$compose_file"
    elif command -v nano &>/dev/null; then
        nano "$compose_file"
    else
        log ERROR "No editor found. Please set the EDITOR environment variable."
        return 1
    fi
}

up_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Starting stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman compose -f "$compose_file" up -d
    else
        docker compose -f "$compose_file" up -d
    fi
}

down_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Stopping stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman compose -f "$compose_file" down
    else
        docker compose -f "$compose_file" down
    fi
}

restart_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Restarting stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman compose -f "$compose_file" restart
    else
        docker compose -f "$compose_file" restart
    fi
}

update_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Updating stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman compose -f "$compose_file" pull
        podman compose -f "$compose_file" up -d
    else
        docker compose -f "$compose_file" pull
        docker compose -f "$compose_file" up -d
    fi
}

remove_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Removing containers for stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman compose -f "$compose_file" down
    else
        docker compose -f "$compose_file" down
    fi
}

delete_stack() {
    local stack_name="$1"
    local mode="$2"

    if [[ -z "$stack_name" || -z "$mode" ]]; then
        log ERROR "Stack name and mode are required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${mode}/${stack_name}"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist in mode '$mode'"
        return 1
    fi

    log WARN "This will permanently delete stack '$stack_name' and all its data"
    read -p -r "Are you sure? (y/N): " confirm

    if [[ "${confirm,,}" != "y" ]]; then
        log INFO "Operation cancelled"
        return 1
    fi

    log INFO "Deleting stack '$stack_name'..."
    rm -rf "$stack_dir"
}

backup_stack() {
    local stack_name="$1"

    if [[ -z "$stack_name" ]]; then
        log ERROR "Stack name is required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${stack_name}"
    local backup_dir="${BACKUP_PATH}/${stack_name}"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist"
        return 1
    fi

    log INFO "Creating backup for stack '$stack_name'..."

    # Create backup directory if it doesn't exist
    sudo mkdir -p "$backup_dir"

    # Create timestamped backup
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local backup_file="${backup_dir}/${stack_name}_${timestamp}.tar.gz"

    # Create tar archive
    tar -czf "$backup_file" -C "$stack_dir" .

    log INFO "Backup created: $backup_file"
}

list_stacks() {
    log INFO "Listing all stacks..."

    for mode in "${MODES[@]}"; do
        local mode_dir="${STACKS_PATH}/${mode}"
        if [[ -d "$mode_dir" ]]; then
            echo -e "\n${bld:-?}${mode^} stacks:${def:-?}"
            find "$mode_dir" -mindepth 1 -maxdepth 1 -type d |
                sed "s|$mode_dir/||" |
                sort
        fi
    done
}

status_stack() {
    local stack_name="$1"

    if [[ -z "$stack_name" ]]; then
        log ERROR "Stack name is required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Showing status for stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman-compose -f "$compose_file" ps
    else
        docker-compose -f "$compose_file" ps
    fi
}

validate_stack() {
    local stack_name="$1"

    if [[ -z "$stack_name" ]]; then
        log ERROR "Stack name is required"
        return 1
    fi

    local stack_dir="${STACKS_PATH}/${stack_name}"
    local compose_file="${stack_dir}/compose.yml"

    if [[ ! -d "$stack_dir" ]]; then
        log ERROR "Stack '$stack_name' does not exist"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log ERROR "No compose file found for stack '$stack_name'"
        return 1
    fi

    log INFO "Validating stack '$stack_name'..."

    # Use appropriate runtime command
    if [[ "$container_runtime" == "podman" ]]; then
        podman-compose -f "$compose_file" config
    else
        docker-compose -f "$compose_file" config
    fi
}

# ============================================
# END OF CSM_FUNCTIONS.SH
# ============================================
