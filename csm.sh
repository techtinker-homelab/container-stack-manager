#!/bin/bash
# =============================================================================
# Container Stack Manager (CSM)
# A unified container stack management tool supporting Docker and Podman
# Author:  Drauku
# License: MIT
# =============================================================================
# Repository file layout (pre-install):
#   ./<repo>/
#   ├── csm.sh
#   ├── csm-install.sh
#   ├── default.conf
#   └── example.env
#
# Installed layout:
#   /srv/stacks/                   ← CSM_ROOT_DIR
#   ├── .backup/
#   │   └── <stack>/<stack>-YYYYMMDD_HHMMSS.tar.gz
#   ├── .common/
#   │   ├── configs/
#   │   │   ├── default.conf
#   │   │   └── user.conf          ← user overrides (optional)
#   │   ├── csm.sh
#   │   ├── example.env
#   │   └── secrets/
#   │       └── <name>.secret
#   └── <stack>/
#       ├── .env
#       ├── compose.yml
#       └── appdata/
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Variable definitions
readonly CSM_VERSION="1.1.0"

# Use lowercase path variables mapped to environment exports
csm_net_name="csm_network"
csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
csm_backup="${csm_dir}/.backup"
csm_common="${csm_dir}/.common"
csm_configs="${csm_common}/configs"
csm_secrets="${csm_common}/secrets"
csm_compose=""

readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Helper functions
_safe_tput() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

_color_setup() {
    if [[ -t 1 ]]; then
        red=$(_safe_tput setaf 1)
        grn=$(_safe_tput setaf 2)
        ylw=$(_safe_tput setaf 3)
        blu=$(_safe_tput setaf 4)
        prp=$(_safe_tput setaf 5)
        cyn=$(_safe_tput setaf 6)
        wht=$(_safe_tput setaf 7)
        blk=$(_safe_tput setaf 0)
        bld=$(_safe_tput bold)
        uln=$(_safe_tput smul)
        rst=$(_safe_tput sgr0)
    else
        red="" grn="" ylw="" blu="" prp="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    fi
}
_color_setup

log() {
    local level="${1:-STEP}" message="${2:-}" color="${rst}" output=""
    case "$level" in
        FAIL) color="${red}"; output=">&2" ;;
        WARN) color="${ylw}"; output=">&2" ;;
        INFO) color="${cyn}" ;;
        PASS) color="${grn}" ;;
        *)    color="${blu}" ;;
    esac
    printf "%s >> %s\n" "${color}${bld}${level}" "${rst}${message}${rst}" ;;
}

_confirm() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" _reply
    [[ "${_reply,,}" == "y" ]]
}

die() { log FAIL "$1"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Bootstrap: load config then functions
_load_bootstrap_config() {
    local cfg_files=(
        "${script_dir}/default.conf"
        "${script_dir}/user.conf"
        "${HOME}/.config/csm/config"
        "${HOME}/.csm/config"
    )
    for f in "${cfg_files[@]}"; do
        [[ -f "$f" ]] && { source "$f"; return 0; }
    done
    # Fallback defaults so the script stays runnable without any conf file
    export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
}

_source_functions() {
    local installed="${CSM_COMMON_DIR:-${CSM_ROOT_DIR:-/srv/stacks}/common}/csm_functions.sh"
    local local_copy="${script_dir}/csm_functions.sh"
    if   [[ -f "$installed"   ]]; then source "$installed"
    elif [[ -f "$local_copy"  ]]; then source "$local_copy"
    else die "csm_functions.sh not found (tried: $installed, $local_copy)"
    fi
}

_load_bootstrap_config
_source_functions

# ---------------------------------------------------------------------------
# 3. Helper functions
show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) v${CSM_VERSION}${rst}

${bld}Usage:${rst} csm <command> [<stack-name>] [options]

${bld}Stack Lifecycle:${rst}
  c  | create   <name>   Create a new stack directory + compose scaffold
  m  | modify   <name>   Open compose.yml in \$EDITOR
  rm | remove   <name>   Stop and remove stack dir (keeps appdata)
  dt | delete   <name>   Stop and PERMANENTLY delete stack + all data
  bu | backup   <name>   Tar-gz the stack directory to backup/

${bld}Stack Operations:${rst}
  u  | up       <name>   Start a stack (docker/podman compose up -d)
  d  | down     <name>   Stop a stack
  b  | bounce   <name>   Stop then start (full recreate)
  r  | restart  <name>   Restart running containers (no recreate)
  ud | update   <name>   Pull latest images then restart

${bld}Information:${rst}
  l  | list              List all stacks in \$CSM_STACKS_DIR
  s  | status   <name>   Show compose ps output
  v  | validate <name>   Validate compose.yml syntax

${bld}Config:${rst}
  cfg | config  <action> show | edit | reload

${bld}Options:${rst}
  -h | --help            Show this help
  -V | --version         Show version
EOF
}

load_config() {
    local config_files=(
        "${csm_common}/configs/default.conf"
        "${csm_common}/configs/user.conf"
        "${HOME}/.config/csm/config"
    )
    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            source "$file"
        fi
    done
}

validate_config() {
    local errors=0
    local required_dirs=("$csm_dir" "$csm_backup" "$csm_common")

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log WARN "Missing directory: $dir. Run install to repair."
            ((errors++))
        fi
    done
    return $errors
}

detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        csm_compose="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        log FAIL "CRITICAL ISSUE! 'docker-compose' is deprecated, upgrade to 'docker compose' to continue."
        return 1
    elif podman compose version >/dev/null 2>&1; then
        csm_compose="podman compose"
    else
        log FAIL "No supported container runtime or compose binary found."
        exit 1
    fi
}

get_stack_dir() {
    local stack_name="${1}"
     "Stack name required"
    echo "${csm_dir}/${stack_name}"
}

# ============================================
# 2. STACK OPERATIONS
create_stack() {
    local stack_name="${1}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name is required"; return 1; }

    local stack_dir
    stack_dir=$(get_stack_dir "$stack_name")

    if [[ -d "$stack_dir" ]]; then
        log FAIL "Stack '$stack_name' already exists at $stack_dir"
        return 1
    fi

    # log INFO "Creating stack '$stack_name'..."
    mkdir -p "${stack_dir}/appdata"

    cat << EOF > "${stack_dir}/compose.yml"
networks:
  default:
    external:
      name: ${csm_net_name}
services:
  # Add services here
EOF
    touch "${stack_dir}/.env"
    log PASS "Stack created in ${stack_dir}"
}

stack_modify() {
    local stack_name="${1}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "Compose file not found: $compose_file"; return 1; }

    local editor="${EDITOR:-vi}"
    "$editor" "$compose_file"
}

stack_up() {
    local stack_name="${1}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    # log INFO "Starting stack '$stack_name' via $csm_compose..."
    if $csm_compose -f "$compose_file" up -d; then
        log PASS "Stack '$stack_name' is up."
    else
        log FAIL "Failed to start stack '$stack_name'."
        return 1
    fi
}

stack_down() {
    local stack_name="${1}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    # log INFO "Stopping stack '$stack_name'..."
    $csm_compose -f "$compose_file" down
}

stack_restart() {
    local stack_name="${1}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    log INFO "Restarting stack '$stack_name'..."
    $csm_compose -f "$compose_file" restart
}

stack_bounce() {
    local stack_name="${1}"
    stack_down "$stack_name"
    stack_up "$stack_name"
}

stack_update() {
    local stack_name="${1:-}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    log INFO "Updating stack '$stack_name'..."
    $csm_compose -f "$compose_file" pull
    $csm_compose -f "$compose_file" up -d
}

stack_delete() {
    local stack_name="${1:-}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local stack_dir="$(get_stack_dir "$stack_name")"
    [[ ! -d "$stack_dir" ]] && { log FAIL "Stack '$stack_name' does not exist."; return 1; }

    # Defensive path checking
    if [[ "$stack_dir" == "/" || "$stack_dir" == "$csm_dir" ]]; then
        log FAIL "Safety trigger: Invalid directory path $stack_dir"
        return 1
    fi

    stack_down "$stack_name" || true

    log WARN "This will PERMANENTLY delete stack '$stack_name' and ALL its data."
    read -r -p "Are you sure? [y/N]: " confirm

    if [[ "${confirm,,}" == "y" ]]; then
        log INFO "Deleting stack '$stack_name'..."
        rm -rf "$stack_dir"
        log PASS "Stack deleted."
    else
        log INFO "Operation cancelled."
    fi
}

stack_backup() {
    local stack_name="${1:-}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local stack_dir="$(get_stack_dir "$stack_name")"
    [[ ! -d "$stack_dir" ]] && { log FAIL "Stack '$stack_name' does not exist."; return 1; }

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local target_backup_dir="${csm_backup}/${stack_name}"
    local backup_file="${target_backup_dir}/${stack_name}_${ts}.tar.gz"

    mkdir -p "$target_backup_dir"
    log INFO "Creating backup: $backup_file"
    tar -czf "$backup_file" -C "$csm_dir" "$stack_name"
    log PASS "Backup complete."
}

stack_list() {
    log INFO "Available Stacks in $csm_dir:"
    if [[ -d "$csm_dir" ]]; then
        find "$csm_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | while read -r st; do
            echo "  - ${cyn}${st}${rst}"
        done
    else
        log FAIL "Stacks directory missing."
    fi
}

stack_status() {
    local stack_name="${1:-}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    $csm_compose -f "$compose_file" ps
}

stack_validate() {
    local stack_name="${1:-}"
    [[ -z "$stack_name" ]] && { log FAIL "Stack name required"; return 1; }

    local compose_file="$(get_stack_dir "$stack_name")/compose.yml"
    [[ ! -f "$compose_file" ]] && { log FAIL "No compose file found for $stack_name"; return 1; }

    $csm_compose -f "$compose_file" config -q && log PASS "Config is valid." || log FAIL "Config is invalid."
}

# ---------------------------------------------------------------------------
# 4. Command dispatcher
main() {
    # Re-apply full config now that functions are loaded
    load_config
    validate_config || true          # warn but don't abort on missing dirs
    detect_compose_command

    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { show_help; exit 0; }
    shift || true

    # Handle flags first
    case "$cmd" in
        -h|--help)    show_help;                  exit 0 ;;
        -V|--version) echo "CSM v${CSM_VERSION}"; exit 0 ;;
    esac

    # Remaining positional args forwarded to each handler
    case "$cmd" in
        c|create)              create_stack     "$@" ;;
        m|modify)              modify_stack     "$@" ;;
        rm|remove)             remove_stack     "$@" ;;
        dt|delete)             delete_stack     "$@" ;;
        bu|backup)             backup_stack     "$@" ;;
        u|up|start)            up_stack         "$@" ;;
        d|dn|down|stop)        down_stack       "$@" ;;
        b|bounce|rc|recreate)  bounce_stack     "$@" ;;
        r|rs|restart)          restart_stack    "$@" ;;
        ud|update)             update_stack     "$@" ;;
        l|ls|list)             list_stacks           ;;
        s|status)              status_stack     "$@" ;;
        v|validate)            validate_stack   "$@" ;;
        t|template)            manage_templates "$@" ;;
        cfg|config)            manage_configs   "$@" ;;
        *) log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
