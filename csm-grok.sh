#!/usr/bin/env bash
# =============================================================================
# csm-grok.sh - Simplified Container Stack Manager
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBALS
# =============================================================================
readonly CSM_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
readonly CSM_CONFIGS_DIR="${CSM_DIR}/.configs"
readonly CSM_NET_NAME="${CSM_NETWORK_NAME:-csm_network}"

csm_cmd=""
csm_debug="0"
scope=""

# =============================================================================
# HELPERS
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
    case "$level" in
        EXIT|FAIL) color="${red}" ;;
        INFO)      color="${cyn}" ;;
        PASS)      color="${grn}" ;;
        WARN)      color="${ylw}" ;;
        *)         color="${ylw}"; level="WARN" ;;
    esac
    printf "%s %-4s >> %s%s\n" "${color}${bld}" "${level}" "${message}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_detect_cmd() {
    if docker compose version >/dev/null 2>&1; then
        csm_cmd="docker"
    elif podman compose version >/dev/null 2>&1; then
        csm_cmd="podman"
    else
        _log EXIT "No supported container runtime found. Install Docker or Podman."
    fi
}

_ensure_docker_for_swarm() {
    if ! command -v docker >/dev/null 2>&1; then
        _log EXIT "Swarm operations require Docker, but Docker is not installed."
    fi
    if [[ "$csm_cmd" != "docker" ]]; then
        _log EXIT "Swarm operations require Docker as the runtime."
    fi
}

_detect_swarm() {
    if [[ "$csm_cmd" == "podman" ]]; then
        return 1
    fi
    local state
    state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo 'inactive')"
    [[ "$state" == "active" ]]
}

_detect_scope() {
    local name="$(_require_name "${1:-}")"
    local dir="$(_get_stack_dir "$name")"

    if [[ -f "${dir}/.swarm" ]]; then
        scope="swarm"
        return
    fi
    if [[ -f "${dir}/.local" ]]; then
        scope="local"
        return
    fi

    if _detect_swarm && docker stack ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qw "$name"; then
        scope="swarm"
    else
        scope="local"
    fi
}

_require_name() {
    if [[ -z "${1:-}" ]]; then _log EXIT "Stack name is required."; fi
    echo "${1:-}"
}

_get_stack_dir() {
    local name="$(_require_name "${1:-}")"
    echo "${CSM_DIR}/${name}"
}

_ensure_compose() {
    local name="$(_require_name "${1:-}")"
    local file="${CSM_DIR}/${name}/compose.yml"
    if [[ ! -f "$file" ]]; then _log EXIT "Compose file not found: $file"; fi
    echo "$file"
}

_confirm() {
    read -r -p "${ylw}${bld} ${1:-Are you sure?} [Y/n]: ${rst}" reply
    [[ "${reply,,}" == "y" || -z "$reply" ]]
}

_create_networks() {
    local networks=("external_edge" "local_network" "internal_only")
    for net in "${networks[@]}"; do
        if ! "$csm_cmd" network inspect "$net" >/dev/null 2>&1; then
            if _detect_swarm; then
                docker network create --driver overlay "$net" >/dev/null 2>&1 \
                    && _log INFO "Created swarm overlay network '$net'" \
                    || _log WARN "Failed to create swarm overlay network '$net'"
            else
                "$csm_cmd" network create "$net" >/dev/null 2>&1 \
                    && _log INFO "Created network '$net'" \
                    || _log WARN "Failed to create network '$net'"
            fi
        else
            _log INFO "Network '$net' already exists."
        fi
    done
}

_setup_ownership() {
    local dir="$1"
    chown -R "${SUDO_UID:-$(id -u)}:2000" "$dir"
    chmod g+s "$dir"
    _log INFO "Set ownership and SGID on $dir"
}

# =============================================================================
# STACK FUNCTIONS
# =============================================================================
stack_create() {
    local name="$(_require_name "${1:-}")"
    local dir="$(_get_stack_dir "$name")"

    if [[ -d "$dir" ]]; then _log EXIT "Stack '$name' already exists."; fi

    mkdir -p "$dir"
    cat > "${dir}/compose.yml" <<EOF
networks:
  ${CSM_NET_NAME}:
    external: true

services:
  app:
    image: nginx:latest
    restart: unless_stopped
    networks:
      - ${CSM_NET_NAME}
EOF

    # Create .env symlink if .env doesn't exist
    if [[ ! -e "${dir}/.env" ]]; then
        local example_env="${CSM_CONFIGS_DIR}/.example.env"
        if [[ -f "$example_env" ]]; then
            ln -s "$example_env" "${dir}/.env"
            _log INFO "Created .env symlink"
        else
            touch "${dir}/.env"
        fi
    fi

    _setup_ownership "$dir"
    _create_networks

    _log PASS "Stack '$name' created."
}

stack_up() {
    local name="$(_require_name "${1:-}")"
    local file="$(_ensure_compose "$name")"
    _detect_scope "$name"
    case "$scope" in
        swarm)
            _ensure_docker_for_swarm
            docker stack deploy -c "$file" "$name"
            _log PASS "Swarm stack '$name' deployed."
            ;;
        local)
            "$csm_cmd" compose -f "$file" up -d --remove-orphans
            _log PASS "Stack '$name' started."
            ;;
    esac
}

stack_down() {
    local name="$(_require_name "${1:-}")"
    local file="$(_ensure_compose "$name")"
    _detect_scope "$name"
    case "$scope" in
        swarm)
            _ensure_docker_for_swarm
            docker stack rm "$name"
            _log PASS "Swarm stack '$name' removed."
            ;;
        local)
            "$csm_cmd" compose -f "$file" down
            _log PASS "Stack '$name' stopped."
            ;;
    esac
}

stack_list() {
    if [[ ! -d "$CSM_DIR" ]]; then _log EXIT "Stacks directory not found: $CSM_DIR"; fi

    local stacks=()
    while IFS= read -r -d '' d; do
        local name="$(basename "$d")"
        if [[ -f "${d}/compose.yml" ]]; then
            stacks+=("$name")
        fi
    done < <(find "$CSM_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)

    if [[ ${#stacks[@]} -gt 0 ]]; then
        _log INFO "Stacks:"
        for name in "${stacks[@]}"; do
            local scope_local
            _detect_scope "$name"
            scope_local="$scope"
            local status="stopped"
            case "$scope_local" in
                swarm)
                    if docker stack ps "$name" >/dev/null 2>&1; then
                        status="deployed"
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "${CSM_DIR}/${name}/compose.yml" ps --services --filter status=running 2>/dev/null | grep -q .; then
                        status="running"
                    fi
                    ;;
            esac
            printf "  %s%-20s%s [%s%s%s] %s%s%s\n" "${cyn}" "$name" "${rst}" "${grn}" "$status" "${rst}" "${blu}" "$scope_local" "${rst}"
        done
    else
        _log INFO "No stacks found."
    fi
}

stack_status() {
    local name="$(_require_name "${1:-}")"
    local file="$(_ensure_compose "$name")"
    _detect_scope "$name"
    case "$scope" in
        swarm)
            _ensure_docker_for_swarm
            docker stack ps "$name"
            ;;
        local)
            "$csm_cmd" compose -f "$file" ps
            ;;
    esac
}

stack_logs() {
    local name="$(_require_name "${1:-}")"
    local file="$(_ensure_compose "$name")"
    local lines="${2:-50}"
    _detect_scope "$name"
    case "$scope" in
        swarm)
            _ensure_docker_for_swarm
            docker service logs --tail "$lines" -f "$name"
            ;;
        local)
            "$csm_cmd" compose -f "$file" logs -f --tail="$lines"
            ;;
    esac
}

stack_bounce() {
    local name="$(_require_name "${1:-}")"
    _log INFO "Bouncing stack '$name' (down then up)..."
    stack_down "$name"
    stack_up "$name"
    _log PASS "Stack '$name' bounced."
}

stack_edit() {
    local name="$(_require_name "${1:-}")"
    local file="$(_ensure_compose "$name")"
    "${EDITOR:-vi}" "$file"
}

stack_backup() {
    local name="$(_require_name "${1:-}")"
    local dir="$(_get_stack_dir "$name")"
    if [[ ! -d "$dir" ]]; then _log EXIT "Stack '$name' not found."; fi

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${CSM_DIR}/.backups/${name}"
    backup_file="${backup_dir}/${name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"
    if tar -czf "$backup_file" -C "$CSM_DIR" "$name" 2>/dev/null; then
        _log PASS "Backup created: $backup_file"
    else
        _log FAIL "Backup failed: $backup_file"
        return 1
    fi
}

stack_remove() {
    local name="$(_require_name "${1:-}")"
    local dir="$(_get_stack_dir "$name")"
    if [[ ! -d "$dir" ]]; then _log EXIT "Stack '$name' not found."; fi
    if ! _confirm "Remove stack '$name'?"; then _log INFO "Cancelled."; return; fi
    _detect_scope "$name"
    case "$scope" in
        swarm)
            docker stack rm "$name" 2>/dev/null || true
            ;;
        local)
            "$csm_cmd" compose -f "${dir}/compose.yml" down 2>/dev/null || true
            ;;
    esac
    rm -rf "$dir"
    _log PASS "Stack '$name' removed."
}

# =============================================================================
# CONFIG
# =============================================================================
config_show() {
    local swarm_status="inactive"
    if _detect_swarm; then swarm_status="active"; fi
    _log INFO "Configuration:"
    printf "  %-20s = %s\n" \
        "Runtime:"      "$csm_cmd" \
        "Swarm:"        "$swarm_status" \
        "Directory:"    "$CSM_DIR" \
        "Network:"      "$CSM_NET_NAME"
}

# =============================================================================
# HELP
# =============================================================================
show_help() {
    cat <<EOF
${bld}Container Stack Manager Grok${rst}

${bld}Usage:${rst} csm-grok.sh <command> [options]

${bld}Commands:${rst}
    c|create <name>     Create a new stack
    up <name>           Start a stack
    down <name>         Stop a stack
    b|bounce <name>     Restart a stack (down then up)
    ls|list             List all stacks
    status <name>       Show stack status
    logs <name> [lines]  Show stack logs (default 50 lines)
    edit <name>         Edit compose file
    backup <name>       Backup a stack
    rm|remove <name>    Remove a stack
    config              Show configuration
    help                Show this help

${bld}Examples:${rst}
    csm-grok.sh c myapp
    csm-grok.sh up myapp
    csm-grok.sh bounce myapp
    csm-grok.sh ls
    csm-grok.sh backup myapp
EOF
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    _color_setup
    _detect_cmd

    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        c|create)   stack_create "$@" ;;
        b|bounce)   stack_bounce "$@" ;;
        d|down)     stack_down "$@" ;;
        u|up)       stack_up "$@" ;;
        ls|list)    stack_list ;;
        status)     stack_status "$@" ;;
        logs)       stack_logs "$@" ;;
        edit)       stack_edit "$@" ;;
        backup)     stack_backup "$@" ;;
        rm|remove)  stack_remove "$@" ;;
        config)     config_show ;;
        help|--help|-h) show_help ;;
        *)          _log EXIT "Unknown command: $cmd. Use 'help' for usage." ;;
    esac
}

main "$@"
