#!/bin/bash
# Installation script for Container Stack Manager

# ============================================
# CONFIGURATION
# ============================================

# Git project file structure pre-installation:
# /$SCRIPT_DIR/
# ├── default.conf
# ├── example.env
# ├── csm
# ├── csm_functions.sh
# └── install.sh

# File-structure post-installation:
# /srv/csm/
# ├── backup/
# │  └── <stackname>/
# │     └── <stackname>-yymmdd-hhmm.tar.gz
# ├── common/
# │  ├── configs/
# │  │  ├── default.conf
# │  │  └── user.conf
# │  ├── csm
# │  ├── csm_functions.sh
# │  ├── example.env
# │  └── secrets/
# │     └── <secretname>.secret
# └── stacks/
#    └── <stackname>/
#       ├── .env
#       ├── compose.yml
#       └── appdata/

# Check if running as root or with sudo
if [ "$(id -u)" -eq 0 ]; then
    # Running as root
    readonly RUNNING_AS_ROOT=true
    readonly var_sudo=""
elif command -v sudo >/dev/null 2>&1; then
    # Not root but sudo is available
    readonly RUNNING_AS_ROOT=false
    readonly var_sudo="sudo"
else
    # Not root and no sudo available
    echo "ERROR: This script must be run as root or with sudo" >&2
    exit 1
fi

# Get script directory
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core utilities
if [[ -f "${SCRIPT_DIR}/csm_functions.sh" ]]; then
    source "${SCRIPT_DIR}/csm_functions.sh"
else
    echo "ERROR: csm_functions.sh not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

# Source configuration to get paths
if [[ -f "${SCRIPT_DIR}/default.conf" ]]; then
    source "${SCRIPT_DIR}/default.conf"
fi

# Set default paths if not configured
export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/csm}"
CSM_COMMON_DIR="${CSM_COMMON_DIR:-${CSM_ROOT_DIR}/common}"
CSM_BACKUP_DIR="${CSM_BACKUP_DIR:-${CSM_ROOT_DIR}/backup}"
CSM_STACKS_DIR="${CSM_STACKS_DIR:-${CSM_ROOT_DIR}/stacks}"
CSM_CONFIGS_DIR="${CSM_CONFIGS_DIR:-${CSM_COMMON_DIR}/configs}"
CSM_SECRETS_DIR="${CSM_SECRETS_DIR:-${CSM_COMMON_DIR}/secrets}"

# ============================================
# HELPER FUNCTIONS
# ============================================
# Define directory structure using configured paths
readonly CSM_DIRS=(
    "${CSM_BACKUP_DIR}"
    "${CSM_COMMON_DIR}"
    "${CSM_STACKS_DIR}"
    "${CSM_CONFIGS_DIR}"
    "${CSM_SECRETS_DIR}"
)

# Directory and file permissions
readonly MODE_AUTH="a-rwx,u=rwX,g=,o="      # 600 # -rw-------
readonly MODE_CONF="a-rwx,u=rwX,g=rwX,o="   # 660 # -rw-rw----
readonly MODE_DATA="a-rwx,u=rwX,g=rwX,o=rX" # 775 # -rwXrwXr-X
readonly MODE_EXEC="a-rwx,u=rwx,g=rwx,o="   # 770 # -rwxrwx---

# File mapping for installation
readonly -A FILES_TO_INSTALL=(
    ["${SCRIPT_DIR}/csm_functions.sh"]="${CSM_COMMON_DIR}/"
    ["${SCRIPT_DIR}/csm"]="${CSM_ROOT_DIR}/"
    ["${SCRIPT_DIR}/csm_install.sh"]="${CSM_COMMON_DIR}/"
    ["${SCRIPT_DIR}/default.conf"]="${CSM_COMMON_DIR}/configs/"
    ["${SCRIPT_DIR}/example.env"]="${CSM_COMMON_DIR}/"
)

# Improved tput Error Handling
_safe_tput() {
    command -v tput >/dev/null 2>&1 || return 1
    tput "$@" 2>/dev/null
}

# Log messages with appropriate level formatting
log() {
    local level="${1}"
    local message="${2}"
    local color=""
    local redirect=""

    case "${level}" in
        "DEBUG")
            if [ "${VERBOSE}" = "true" ]; then
                color="$(_safe_tput setaf 4)"
            fi
            ;;
        "INFO") color="$(_safe_tput setaf 6)";;
        "FAILURE") color="$(_safe_tput setaf 1)"; redirect=">&2" ;;
        "SUCCESS") color="$(_safe_tput setaf 2)";;
        "WARNING") color="$(_safe_tput setaf 3)"; redirect=">&2";;
        *)
            color="$(_safe_tput sgr0)"
            ;;
    esac
    printf "[%s%s%s] %s\n" "${color}" "${level}" "$(_safe_tput sgr0)" "${message}" ${redirect}
}

# Helper function to install files/directories with proper permissions
install_secure() {
    local src="$1"
    local tgt="$2"
    local mode="$3"
    local create="${4:-false}"
    local owner="${5:-$CSM_OWNER}"
    local group="${6:-$CSM_GROUP}"

    if [[ "$create" == "true" ]]; then
        if [[ ! -d "$tgt" ]]; then
            ${var_sudo} install -o "$owner" -g "$group" -m "$mode" -d "$tgt"
            log INFO "Created directory: $tgt"
        fi
    elif [[ -f "$src" ]]; then
        ${var_sudo} install -o "$owner" -g "$group" -m "$mode" "$src" "$tgt"
        log INFO "Installed: $tgt/$(basename "$src")"
    fi
}

# Function to create CSM directory structure
setup_csm_directories() {
    log INFO "Setting up CSM directory structure in ${CSM_ROOT_DIR}..."

    # Create all required directories
    for dir in "${CSM_DIRS[@]}"; do
        install_secure "" "$dir" "$MODE_DATA" "true"
    done

    # Install core files
    log INFO "Installing core files..."
    for src in "${!FILES_TO_INSTALL[@]}"; do
        local tgt="${FILES_TO_INSTALL[$src]}"
        install_secure "$src" "$tgt" "$MODE_EXEC"
    done

    # Create symlink to main script if not in dev mode
    local bin_dir="${CSM_BIN_DIR:-/usr/local/bin}"
    if [[ "$CSM_ROOT_DIR" != "$REPO_ROOT" && ! -L "${bin_dir}/csm" ]]; then
        ${var_sudo} mkdir -p "$(dirname "${bin_dir}/csm")"
        ${var_sudo} ln -sf "${CSM_ROOT_DIR}/csm" "${bin_dir}/csm"
        ${var_sudo} chown "${CSM_OWNER:-$(id -u)}:${CSM_GROUP:-$(id -g)}" "${bin_dir}/csm"
        log INFO "Created symlink: ${bin_dir}/csm -> ${CSM_ROOT_DIR}/csm"
    fi

    # Define directory structure based on base.conf
    declare -A dir_configs
    dir_configs["${CSM_ROOT_DIR}/backup"]="$MODE_DATA"
    dir_configs["${CSM_ROOT_DIR}/common"]="$MODE_CONF"
    dir_configs["${CSM_ROOT_DIR}/common/configs"]="$MODE_CONF"
    dir_configs["${CSM_ROOT_DIR}/common/secrets"]="$MODE_AUTH"
    dir_configs["${CSM_ROOT_DIR}/stacks"]="$MODE_DATA"

    # Create all configured directories
    for dir in "${!dir_configs[@]}"; do
        local mode="${dir_configs[$dir]}"
        if [[ -n "$dir" && ! -d "$dir" ]]; then
            install_secure "" "$dir" "$mode" "true"
        fi
    done

    # Create default environment file if it doesn't exist
    local env_template="${REPO_ROOT}/conf/example.env"
    local env_file="${CSM_ROOT_DIR}/common/configs/example.env"

    if [[ ! -f "$env_file" ]]; then
        if [[ -f "$env_template" ]]; then
            install_secure "$env_template" "$env_file" "$MODE_CONF"
            # log INFO "Created environment file from template: $env_file"
        else
            install_secure "" "$env_file" "$MODE_CONF"
            # log INFO "Created empty environment file: $env_file"
        fi
    fi

    # Function to handle template repository operations
    clone_or_update_template_repo() {
        local template_branch="${CSM_TEMPLATE_BRANCH:-main}"
        
        # Ensure templates directory exists and is empty
        if [[ ! -d "${CSM_TEMPLATES_DIR}" ]]; then
            if ! mkdir -p "${CSM_TEMPLATES_DIR}"; then
                log ERROR "Failed to create templates directory: ${CSM_TEMPLATES_DIR}"
                return 1
            fi
            chmod 750 "${CSM_TEMPLATES_DIR}"
        else
            # Backup existing templates if any exist
            local backup_dir
            backup_dir="${CSM_BACKUP_DIR}/templates_$(date +%Y%m%d_%H%M%S)"
            if [[ "$(ls -A "${CSM_TEMPLATES_DIR}" 2>/dev/null)" ]]; then
                log INFO "Backing up existing templates to ${backup_dir}"
                # First check if directory exists, if not create it
                if [[ ! -d "${backup_dir}" ]]; then
                    if ! mkdir -p "${backup_dir}"; then
                        log ERROR "Failed to create backup directory: ${backup_dir}"
                        # Skip the copy operation if directory creation failed
                    else
                        # Directory was created successfully, proceed with copy
                        cp -r "${CSM_TEMPLATES_DIR}/"* "${backup_dir}/" 2>/dev/null || true
                    fi
                else
                    # Directory already exists, proceed with copy
                    cp -r "${CSM_TEMPLATES_DIR}/"* "${backup_dir}/" 2>/dev/null || true
                fi
            fi
        fi

        # Clone or update the repository directly into CSM_TEMPLATES_DIR
        if [[ -d "${CSM_TEMPLATES_DIR}/.git" ]]; then
            log INFO "Updating template repository in ${CSM_TEMPLATES_DIR}..."
            if ! git -C "${CSM_TEMPLATES_DIR}" fetch --all || \
               ! git -C "${CSM_TEMPLATES_DIR}" checkout "${template_branch}" || \
               ! git -C "${CSM_TEMPLATES_DIR}" pull origin "${template_branch}"; then
                log WARN "Failed to update template repository"
                return 1
            fi
        else
            log INFO "Cloning template repository from ${CSM_TEMPLATE_REPO}..."
            local repo_url="https://github.com/${CSM_TEMPLATE_REPO}.git"
            if [[ "${CSM_TEMPLATE_SOURCE:-github}" == "gitlab" ]]; then
                repo_url="https://gitlab.com/${CSM_TEMPLATE_REPO}.git"
            fi

            # Create a temporary directory for the clone
            local temp_dir
            temp_dir="$(mktemp -d)"

            # Clone to temp directory first
            if ! git clone --depth 1 --branch "${template_branch}" "${repo_url}" "${temp_dir}"; then
                log ERROR "Failed to clone template repository"
                rm -rf "${temp_dir}"
                return 1
            fi

            # Move contents to templates directory
            find "${temp_dir}" -mindepth 1 -maxdepth 1 -exec mv {} "${CSM_TEMPLATES_DIR}/" \;
            rmdir "${temp_dir}"
        fi

        # Set proper permissions
        if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
            chown -R "${SUDO_UID}:${SUDO_GID}" "${CSM_TEMPLATES_DIR}" || {
                log WARN "Failed to set ownership of template repository"
            }
        fi

        log SUCCESS "Template repository setup complete: ${CSM_TEMPLATES_DIR}"
    }

    # Set secure permissions
    chmod 750 "${CSM_ROOT_DIR}" "${CSM_BACKUP_DIR}" "${CSM_STACKS_DIR}" "${CSM_CONFIGS_DIR}"
    chmod 700 "${CSM_COMMON_DIR}" "${CSM_SECRETS_DIR}" "${CSM_TEMPLATES_DIR}"

    # Create environment files if they don't exist
    local env_files=(".container.env" ".local.env" ".swarm.env")
    for env_file in "${env_files[@]}"; do
        local file_path="${CSM_ROOT_DIR}/${env_file}"
        install_secure "" "$file_path" "$MODE_CONF"
        # log INFO "Created environment file: $file_path"
    done
}

# Function to set up configuration files
setup_config() {
    log INFO "Setting up configuration files..."

    # Create configs directory if it doesn't exist
    if [[ ! -d "${CSM_CONFIGS_DIR}" ]]; then
        if ! mkdir -p "${CSM_CONFIGS_DIR}"; then
            log ERROR "Failed to create config directory: ${CSM_CONFIGS_DIR}"
            return 1
        fi
    fi

    local default_config="${CSM_CONFIGS_DIR}/default.conf"
    local user_config="${CSM_CONFIGS_DIR}/user.conf"

    # Create default config if it doesn't exist
    if [[ ! -f "${default_config}" ]]; then
        log INFO "Creating default configuration..."
        if ! cp "${SCRIPT_DIR}/default.conf" "${default_config}"; then
            log ERROR "Failed to create default configuration"
            return 1
        fi
        chmod 640 "${default_config}"
        log INFO "Created default configuration: ${default_config}"
    fi

    # Create user config if it doesn't exist
    if [[ ! -f "${user_config}" ]]; then
        log INFO "Creating user configuration..."
        cat > "${user_config}" << 'EOF'
# Container Stack Manager User Configuration
# This file overrides values from default.conf
# Add your custom configurations here

# Example overrides:
# CSM_CONTAINER_RUNTIME=docker
# CSM_ROOT_DIR=/opt/csm
# CSM_TEMPLATE_REPO=your-username/your-templates
# CSM_NETWORK_SUBNET=192.168.1.0/24
EOF
        chmod 600 "${user_config}"
        log INFO "Created user configuration: ${user_config}"
    fi

    # Create example environment file if it doesn't exist
    local example_env="${CSM_COMMON_DIR}/example.env"
    if [[ ! -f "${example_env}" ]]; then
        log INFO "Creating example environment file..."
        cat > "${example_env}" << 'EOF'
# Example Environment Variables
# Copy this file to your stack directory and rename to .env
# Then update the values as needed

# Basic settings
COMPOSE_PROJECT_NAME=myapp
TZ=UTC
PUID=1000
PGID=1000

# Network settings
# SUBNET=192.168.90.0/24
# GATEWAY=192.168.90.1

# Volume settings
# DATA_DIR=/path/to/data
# CONFIG_DIR=/path/to/config

# Service-specific settings
# MYSQL_ROOT_PASSWORD=changeme
# MYSQL_DATABASE=appdb
# MYSQL_USER=appuser
# MYSQL_PASSWORD=secret
EOF
        chmod 640 "${example_env}"
        log INFO "Created example environment file: ${example_env}"
    fi

    log SUCCESS "Configuration setup completed successfully"
    return 0
}

# Function to install dependencies
install_dependencies() {
    log INFO "Installing dependencies..."

    # Check for sudo access
    if ! sudo -n true 2>/dev/null; then
        log ERROR "Please run this script with sudo privileges"
        exit 1
    fi

    # Install required packages
    case "$(uname -s)" in
        Linux)
            if command -v apt-get &>/dev/null; then
                sudo apt-get update
                sudo apt-get install -y curl wget git
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y curl wget git
            else
                log WARN "Could not determine package manager"
            fi
            ;;
        Darwin)
            if ! command -v brew &>/dev/null; then
                log ERROR "Homebrew not found. Please install Homebrew first."
                exit 1
            fi
            brew install curl wget git
            ;;
        *)
            log WARN "Unsupported OS. Please install dependencies manually."
            ;;
    esac
}

# Main installation function
install_csm() {
    log INFO "Starting Container Stack Manager installation..."
    log INFO "Installation directory: ${CSM_ROOT_DIR}"

    # Check for required commands
    local required_commands=("git" "docker" "docker-compose")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log ERROR "Required command not found: ${cmd}"
            return 1
        fi
    done

    # Create directories
    log INFO "Setting up directory structure..."
    if ! setup_csm_directories; then
        log ERROR "Failed to set up CSM directories"
        return 1
    fi

    # Set up configuration
    log INFO "Setting up configuration..."
    if ! setup_config; then
        log ERROR "Failed to set up configuration"
        return 1
    fi

    # Source the configuration to get the latest values
    if [[ -f "${CSM_CONFIGS_DIR}/default.conf" ]]; then
        source "${CSM_CONFIGS_DIR}/default.conf"
    fi
    if [[ -f "${CSM_CONFIGS_DIR}/user.conf" ]]; then
        source "${CSM_CONFIGS_DIR}/user.conf"
    fi

    # Install dependencies
    log INFO "Installing dependencies..."
    if ! install_dependencies; then
        log ERROR "Failed to install dependencies"
        return 1
    fi

    # Ask user if they want to clone the template repository
    if [[ -n "${CSM_TEMPLATE_REPO:-}" ]]; then
        log INFO "Template repository is configured as: ${CSM_TEMPLATE_REPO}"
        read -r -p "Would you like to clone/update the template repository? [y/N] " clone_templates

        if [[ "$clone_templates" =~ ^[Yy]$ ]]; then
            clone_or_update_template_repo || return 1
        else
            log INFO "Skipping template repository setup"
        fi
    else
        log INFO "No template repository configured (set CSM_TEMPLATE_REPO in config to enable)"
    fi

    # Create symlink in /usr/local/bin if not exists
    local bin_path="/usr/local/bin/csm"
    if [[ ! -L "${bin_path}" && ! -e "${bin_path}" ]]; then
        log INFO "Creating symlink in /usr/local/bin..."
        ${var_sudo} ln -sf "${CSM_COMMON_DIR}/csm" "${bin_path}" || {
            log WARN "Failed to create symlink in /usr/local/bin, you may need to add ${CSM_COMMON_DIR} to your PATH"
        }
    fi

    # Set final permissions
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        ${var_sudo} chown -R "${SUDO_UID}:${SUDO_GID}" "${CSM_ROOT_DIR}" || {
            log WARN "Failed to set ownership of ${CSM_ROOT_DIR}"
        }
    elif [ "${RUNNING_AS_ROOT:-false}" = false ]; then
        # If not running as root and no SUDO_UID/SUDO_GID, use current user
        ${var_sudo} chown -R "$(id -u):$(id -g)" "${CSM_ROOT_DIR}" || {
            log WARN "Failed to set ownership of ${CSM_ROOT_DIR}"
        }
    fi

    log SUCCESS "\nContainer Stack Manager installed successfully!"
    log INFO "\nNext steps:"
    log INFO "1. Edit configuration: ${CSM_CONFIGS_DIR}/user.conf"
    log INFO "2. Add your stacks to: ${CSM_STACKS_DIR}"
    log INFO "3. Use 'csm' command to manage your stacks"

    return 0
}

# Function to get template repository URL based on source
# Usage: get_template_url <repo_name> [branch] [source] [url_type]
#   repo_name: Repository name (e.g., 'username/repo')
#   branch: Branch name (default: 'main')
#   source: 'github', 'gitlab', or custom domain (default: 'github')
#   url_type: 'web' for web browser URL, 'git' for git clone URL (default: 'web')
get_template_url() {
    local repo_name="$1"
    local branch="${2:-main}"
    local source="${3:-github}"
    local url_type="${4:-web}"  # 'web' or 'git'

    case "${source,,}" in
        gitlab)
            if [[ "${url_type}" == "git" ]]; then
                echo "https://gitlab.com/${repo_name}.git"
            else
                echo "https://gitlab.com/${repo_name}/-/tree/${branch}"
            fi
            ;;
        github)
            if [[ "${url_type}" == "git" ]]; then
                echo "https://github.com/${repo_name}.git"
            else
                echo "https://github.com/${repo_name}/tree/${branch}"
            fi
            ;;
        gitea)
            if [[ "${url_type}" == "git" ]]; then
                echo "https://${source#gitea://}/${repo_name}.git"
            else
                echo "https://${source#gitea://}/${repo_name}/src/branch/${branch}"
            fi
            ;;
        *)
            # Handle custom URLs
            if [[ "${source,,}" == http* ]]; then
                # If source is already a URL, use it directly
                if [[ "${url_type}" == "git" ]]; then
                    # For git URLs, ensure it ends with .git
                    if [[ "${source}" != *.git ]]; then
                        echo "${source}${source: -1:1}/.git"  # Add .git if not present, handling trailing slash
                    else
                        echo "${source}"
                    fi
                else
                    # For web URLs, just return as is
                    echo "${source}"
                fi
            else
                # For unknown sources, assume it's a domain and use https
                if [[ "${url_type}" == "git" ]]; then
                    echo "https://${source}/${repo_name}.git"
                else
                    echo "https://${source}/${repo_name}"
                fi
            fi
            ;;
    esac
}

install_csm