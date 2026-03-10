    #!/usr/bin/env bash
# ------------------------------------------------------------------
# Container Stack Manager – Install script
# ------------------------------------------------------------------
#  • Installs Docker (if missing)
#  • Creates a dedicated docker user/group (UID/GID 2000)
#  • Performs all the original installation steps
# ------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------
# Helper utilities
# ------------------------------------------------------------------
_safe_tput() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null; }

log() {
  local level=$1 msg=$2
  local color="" redirect=""
  case "$level" in
    STEP) color=$(_safe_tput setaf 4) && [[ $VERBOSE = true ]] ;;
    INFO) color=$(_safe_tput setaf 6) ;;
    FAIL) color=$(_safe_tput setaf 1); redirect=">&2" ;;
    PASS) color=$(_safe_tput setaf 2) ;;
    WARN) color=$(_safe_tput setaf 3); redirect=">&2" ;;
    *)    color=$(_safe_tput sgr0) ;;
  esac
  printf "[%s%s%s] %s\n" "$color" "$level" "$(_safe_tput sgr0)" "$msg" $redirect
}

# ------------------------------------------------------------------
# Check for root / sudo
# ------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  readonly RUNNING_AS_ROOT=true
  readonly var_sudo=""
else
  if command -v sudo >/dev/null 2>&1; then
    readonly RUNNING_AS_ROOT=false
    readonly var_sudo="sudo"
  else
    echo "ERROR: This script must be run as root or with sudo" >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------
# Locate the script directory
# ------------------------------------------------------------------
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------
# Load core utilities and config
# ------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/csm_functions.sh" ]]; then
  source "${SCRIPT_DIR}/csm_functions.sh"
else
  echo "FAIL: csm_functions.sh not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

if [[ -f "${SCRIPT_DIR}/default.conf" ]]; then
  source "${SCRIPT_DIR}/default.conf"
fi

# Set defaults if not defined by default.conf
export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
CSM_COMMON_DIR="${CSM_COMMON_DIR:-${CSM_ROOT_DIR}/.common}"
CSM_BACKUP_DIR="${CSM_BACKUP_DIR:-${CSM_ROOT_DIR}/.backup}"
CSM_STACKS_DIR="${CSM_STACKS_DIR:-${CSM_ROOT_DIR}/stacks}"
CSM_CONFIGS_DIR="${CSM_CONFIGS_DIR:-${CSM_COMMON_DIR}/configs}"
CSM_SECRETS_DIR="${CSM_SECRETS_DIR:-${CSM_COMMON_DIR}/secrets}"

# ------------------------------------------------------------------
# File/dir permissions
# ------------------------------------------------------------------
readonly MODE_AUTH="a-rwx,u=rwX,g=,o="      # 600
readonly MODE_CONF="a-rwx,u=rwX,g=rwX,o="   # 660
readonly MODE_DATA="a-rwx,u=rwX,g=rwX,o=rX" # 775
readonly MODE_EXEC="a-rwx,u=rwx,g=rwx,o="   # 770

# ------------------------------------------------------------------
# Map source files → target dirs
# ------------------------------------------------------------------
readonly -A FILES_TO_INSTALL=(
  ["${SCRIPT_DIR}/csm_functions.sh"]="${CSM_COMMON_DIR}/"
  ["${SCRIPT_DIR}/csm"]="${CSM_ROOT_DIR}/"
  ["${SCRIPT_DIR}/csm_install.sh"]="${CSM_COMMON_DIR}/"
  ["${SCRIPT_DIR}/default.conf"]="${CSM_COMMON_DIR}/configs/"
  ["${SCRIPT_DIR}/example.env"]="${CSM_COMMON_DIR}/"
)

# ------------------------------------------------------------------
# Helper: install files/directories with proper perms
# ------------------------------------------------------------------
install_secure() {
  local src=$1 tgt=$2 mode=$3 create=${4:-false} owner=${5:-$CSM_OWNER} group=${6:-$CSM_GROUP}

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

# ------------------------------------------------------------------
# Create the docker user/group (UID/GID 2000)
# ------------------------------------------------------------------
create_docker_user_group() {
  local uid=2000 gid=2000

  # Group
  if getent group "$gid" >/dev/null 2>&1; then
    log INFO "Group 'docker' (GID $gid) already exists"
  else
    ${var_sudo} groupadd -g "$gid" docker || {
      log FAIL "Failed to create group 'docker'"
      exit 1
    }
    log INFO "Created group 'docker' (GID $gid)"
  fi

  # User
  if getent passwd "$uid" >/dev/null 2>&1; then
    log INFO "User 'docker' (UID $uid) already exists"
  else
    ${var_sudo} useradd -m -u "$uid" -g docker -s /usr/sbin/nologin docker || {
      log FAIL "Failed to create user 'docker'"
      exit 1
    }
    log INFO "Created user 'docker' (UID $uid) with home /home/docker"
  fi
}

# ------------------------------------------------------------------
# Install Docker (if not present)
# ------------------------------------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    # log INFO "Docker already installed"
    return 0
  fi

  log INFO "Installing Docker..."
  ${var_sudo} curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || {
    log FAIL "Failed to download Docker installer"
    exit 1
  }

  ${var_sudo} sh /tmp/get-docker.sh || {
    log FAIL "Docker installation failed"
    exit 1
  }

  ${var_sudo} rm -f /tmp/get-docker.sh
  log PASS "Docker installed successfully"
}

# ------------------------------------------------------------------
# Set up CSM directory structure
# ------------------------------------------------------------------
setup_csm_directories() {
  log INFO "Setting up CSM directory structure in ${CSM_ROOT_DIR}..."

  # Directories to create
  local -a CSM_DIRS=(
    "$CSM_BACKUP_DIR"
    "$CSM_COMMON_DIR"
    "$CSM_STACKS_DIR"
    "$CSM_CONFIGS_DIR"
    "$CSM_SECRETS_DIR"
  )

  for dir in "${CSM_DIRS[@]}"; do
    install_secure "" "$dir" "$MODE_DATA" "true"
  done

  # Install core files
  log INFO "Installing core files..."
  for src in "${!FILES_TO_INSTALL[@]}"; do
    local tgt="${FILES_TO_INSTALL[$src]}"
    install_secure "$src" "$tgt" "$MODE_EXEC"
  done

  # Symlink main script
  local bin_dir="${CSM_BIN_DIR:-/usr/local/bin}"
  if [[ "$CSM_ROOT_DIR" != "$REPO_ROOT" && ! -L "${bin_dir}/csm" ]]; then
    ${var_sudo} mkdir -p "$(dirname "${bin_dir}/csm")"
    ${var_sudo} ln -sf "${CSM_ROOT_DIR}/csm" "${bin_dir}/csm"
    ${var_sudo} chown "${CSM_OWNER:-$(id -u)}:${CSM_GROUP:-$(id -g)}" "${bin_dir}/csm"
    log INFO "Created symlink: ${bin_dir}/csm -> ${CSM_ROOT_DIR}/csm"
  fi

  # Additional directories with specific perms
  declare -A dir_configs
  dir_configs["${CSM_ROOT_DIR}/backup"]="$MODE_DATA"
  dir_configs["${CSM_ROOT_DIR}/common"]="$MODE_CONF"
  dir_configs["${CSM_ROOT_DIR}/common/configs"]="$MODE_CONF"
  dir_configs["${CSM_ROOT_DIR}/common/secrets"]="$MODE_AUTH"
  dir_configs["${CSM_ROOT_DIR}/stacks"]="$MODE_DATA"

  for dir in "${!dir_configs[@]}"; do
    local mode="${dir_configs[$dir]}"
    if [[ -n "$dir" && ! -d "$dir" ]]; then
      install_secure "" "$dir" "$mode" "true"
    fi
  done

  # Create example environment file
  local example_env="${CSM_COMMON_DIR}/example.env"
  if [[ ! -f "$example_env" ]]; then
    cat > "$example_env" <<'EOF'
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
    chmod 640 "$example_env"
    log INFO "Created example environment file: $example_env"
  fi

  log PASS "Configuration setup completed successfully"
}

# ------------------------------------------------------------------
# Install dependencies (curl, wget, git)
# ------------------------------------------------------------------
install_dependencies() {
  log INFO "Installing dependencies..."

  # Detect distro & install
  if command -v apt-get >/dev/null 2>&1; then
    ${var_sudo} apt-get update
    ${var_sudo} apt-get install -y curl wget git
  elif command -v dnf >/dev/null 2>&1; then
    ${var_sudo} dnf install -y curl wget git
  else
    log WARN "Unsupported package manager – install dependencies manually"
  fi
}

# ------------------------------------------------------------------
# Main installation routine
# ------------------------------------------------------------------
install_csm() {
  log INFO "Starting Container Stack Manager installation..."
  log INFO "Installation directory: ${CSM_ROOT_DIR}"

  # 1. Ensure Docker user/group
  create_docker_user_group

  # 2. Install Docker if missing
  install_docker

  # 3. Create directories
  setup_csm_directories

  # 4. Load configuration (may override defaults)
  if [[ -f "${CSM_CONFIGS_DIR}/default.conf" ]]; then
    source "${CSM_CONFIGS_DIR}/default.conf"
  fi
  if [[ -f "${CSM_CONFIGS_DIR}/user.conf" ]]; then
    source "${CSM_CONFIGS_DIR}/user.conf"
  fi

  # 5. Install other dependencies
  install_dependencies

  # 6. Check required commands
  local required=("git" "docker" "docker-compose")
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log FAIL "Required command not found: $cmd"
      exit 1
    fi
  done

  # 7. Optional template repo
  if [[ -n "${CSM_TEMPLATE_REPO:-}" ]]; then
    log INFO "Template repository configured: ${CSM_TEMPLATE_REPO}"
    read -r -p "Clone/update the template repository? [y/N] " clone_templates
    if [[ "$clone_templates" =~ ^[Yy]$ ]]; then
      clone_or_update_template_repo || { log FAIL "Failed to set up template repo"; exit 1; }
    else
      log INFO "Skipping template repository setup"
    fi
  else
    log INFO "No template repository configured"
  fi

  # 8. Symlink /usr/local/bin/csm if not present
  local bin_path="/usr/local/bin/csm"
  if [[ ! -L "$bin_path" && ! -e "$bin_path" ]]; then
    ${var_sudo} ln -sf "${CSM_COMMON_DIR}/csm" "$bin_path" || {
      log WARN "Failed to create symlink; add ${CSM_COMMON_DIR} to PATH"
    }
  fi

  # 9. Final ownership
  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    ${var_sudo} chown -R "${SUDO_UID}:${SUDO_GID}" "${CSM_ROOT_DIR}"
  elif [ "$RUNNING_AS_ROOT" = false ]; then
    ${var_sudo} chown -R "$(id -u):$(id -g)" "${CSM_ROOT_DIR}"
  fi

  log PASS "\nContainer Stack Manager installed successfully!"
  log INFO "\nNext steps:"
  log INFO "1. Edit configuration: ${CSM_CONFIGS_DIR}/user.conf"
  log INFO "2. Add your stacks to: ${CSM_STACKS_DIR}"
  log INFO "3. Use 'csm' command to manage your stacks"
}

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------
install_csm
