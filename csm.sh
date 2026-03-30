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
#   │   ├── secrets/
#   │   |    └── <variable_name>.secret
#   │   └── templates/
#   │        └── <stack>/
#   │            ├── compose.yml
#   │            └── example.env
#   └── <stack>/
#       ├── .env
#       ├── compose.yml
#       └── appdata/
# =============================================================================

set -euo pipefail

readonly CSM_VERSION="1.1.0"
readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# =============================================================================
# 1. COLORS AND LOGGING
# =============================================================================

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

# log() # BUG! - passing a variable as stdout prints the literal var, not redirecting output
#     local level="${1:-STEP}" message="${2:-}" color="${rst}" output=""
#     case "$level" in
#         FAIL) color="${red}"; output=">&2" ;;
#         WARN) color="${ylw}"; output=">&2" ;;
#         INFO) color="${cyn}" ;;
#         PASS) color="${grn}" ;;
#         *)    color="${blu}" ;;
#     esac
#     printf "%s >> %s %s\n" "${color}${bld}${level}" "${rst}${message}${rst}" "${output}"
# }
log() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        FAIL) printf "%s FAIL >> %s%s\n" "${red}${bld}" "${message}" "${rst}" >&2 ;;
        WARN) printf "%s WARN >> %s%s\n" "${ylw}${bld}" "${message}" "${rst}" >&2 ;;
        INFO) printf "%s INFO >> %s%s\n" "${cyn}${bld}" "${message}" "${rst}" ;;
        PASS) printf "%s PASS >> %s%s\n" "${grn}${bld}" "${message}" "${rst}" ;;
        *)    printf "%s STEP >> %s%s\n" "${blu}${bld}" "${message}" "${rst}" ;;
    esac
}
die() { log FAIL "$1"; exit 1; }

_confirm() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" _reply
    [[ "${_reply,,}" == "y" ]]
}

# =============================================================================
# 2. CONFIGURATION
# =============================================================================

csm_cmd=""    # set by detect_compose_command

load_config() {
    # Ensure 'user.conf' is the last file sourced
    for f in \
        "${script_dir}/.common/configs/"*.conf \
        "${script_dir}/.common/configs/user.conf" \
        "${HOME}/.config/csm/"*.conf \
        "${HOME}/.config/csm/user.conf"
    do [[ -f "$f" ]] && source "$f"
    done

    # Apply env-var overrides so exported vars always win
    stacks_dir="${CSM_ROOT_DIR:-/srv/stacks}"
    csm_backup="${CSM_BACKUP_DIR:-${stacks_dir}/.backup}"
    csm_common="${CSM_COMMON_DIR:-${stacks_dir}/.common}"
    csm_configs="${CSM_CONFIGS_DIR:-${csm_common}/configs}"
    csm_secrets="${CSM_SECRETS_DIR:-${csm_common}/secrets}"
    csm_template="${CSM_TEMPLATE_DIR:-${csm_common}/template}"
    csm_net_name="${CSM_NETWORK_NAME:-csm_network}"
}

validate_config() {
    local errors=0
    for dir in "$stacks_dir" "$csm_backup" "$csm_common"; do
        if [[ ! -d "$dir" ]]; then
            log WARN "Directory not found: $dir  (run csm-install.sh to repair)"
            (( errors++ )) || true
        fi
    done
    return $errors
}

detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        csm_cmd="docker compose"
    elif podman compose version >/dev/null 2>&1; then
        csm_cmd="podman compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        die "'docker-compose' v1 is unsupported. Upgrade to 'docker compose' (v2)."
    else
        die "No supported container runtime found. Install Docker or Podman."
    fi
}

# =============================================================================
# 3. INTERNAL HELPERS
# =============================================================================

_require_name() {
    [[ -n "${1:-}" ]] || die "Stack name is required."
    echo "$1"
}

get_stack_dir() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    echo "${stacks_dir}/${stack_name}"
}

_require_compose_file() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f="${stacks_dir}/${stack_name}/compose.yml"
    [[ -f "$f" ]] || die "Compose file not found: $f"
    echo "$f"
}

# =============================================================================
# 4. STACK LIFECYCLE
# =============================================================================

stack_create() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] && die "Stack '$stack_name' already exists at $stack_dir"

    mkdir -p "${stack_dir}/appdata"
    cat > "${stack_dir}/compose.yml" <<EOF
networks:
  default:
    external:
      name: ${csm_net_name}

services:
  # Add your service definitions here
  # example:
  #   image: nginx:alpine
  #   restart: unless-stopped
EOF
    touch "${stack_dir}/.env"
    log PASS "Stack '$stack_name' created at ${stack_dir}"
}

stack_modify() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    "${EDITOR:-vi}" "$f"
}

stack_backup() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found."

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${csm_backup}/${stack_name}"
    backup_file="${backup_dir}/${stack_name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"
    log INFO "Creating backup: $backup_file"
    tar -czf "$backup_file" -C "$stacks_dir" "$stack_name"
    log PASS "Backup complete: $backup_file"
}

stack_remove() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found at $stack_dir"

    _confirm "Remove stack '$stack_name'? (all running stack containers will be removed)" \
        || { log INFO "Cancelled."; return 0; }

    local f; f="$(_require_compose_file "$stack_name")"
    local containers
    containers=$($csm_cmd -f "$f" ps -q 2>/dev/null) || true
    if [[ -n "$containers" ]]; then
        $csm_cmd -f "$f" rm --stop --force
        # $csm_cmd -f "$f" down --rmi none --volumes=false #needs testing
    fi
    log PASS "Stack '$stack_name' containers removed."
}

stack_delete() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found at $stack_dir"
    [[ "$stack_dir" == "/" || "$stack_dir" == "$stacks_dir" ]] && \
        die "Safety guard: refusing to delete $stack_dir"

    log WARN "This will PERMANENTLY delete '$stack_name' and ALL associated appdata."
    _confirm "Confirm DELETE of $stack_dir?" || { log INFO "Cancelled."; return 0; }

    stack_stop "$stack_name" 2>/dev/null || true
    rm -rf "$stack_dir"
    log PASS "Stack '$stack_name' deleted."
}

# =============================================================================
# 5. STACK OPERATIONS
# =============================================================================

stack_start() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    $csm_cmd -f "$f" up -d \
        && log PASS "Stack '$stack_name' is up." \
        || die "Failed to start stack '$stack_name'."
}

stack_stop() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    $csm_cmd -f "$f" down \
        && log PASS "Stack '$stack_name' stopped." \
        || die "Failed to stop stack '$stack_name'."
}

stack_restart() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    log INFO "Restarting stack '$stack_name'..."
    $csm_cmd -f "$f" restart \
        && log PASS "Stack '$stack_name' restarted."
}

stack_bounce() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    log INFO "Bouncing stack '$stack_name'..."
    stack_stop "$stack_name"
    stack_start   "$stack_name"
}

stack_update() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    log INFO "Pulling latest images for '$stack_name'..."
    $csm_cmd -f "$f" pull
    $csm_cmd -f "$f" up -d \
        && log PASS "Stack '$stack_name' updated."
}

# =============================================================================
# 6. INFORMATION
# =============================================================================

stack_list() {
    [[ -d "$stacks_dir" ]] || die "Stacks directory not found: $stacks_dir"
    log INFO "Stacks in ${stacks_dir}:"
    local found=0
    while IFS= read -r -d '' stack_dir; do
        local dir_name status_label status_color
        dir_name="$(basename "$stack_dir")"
        if $csm_cmd -f "${stack_dir}/compose.yml" ps --services \
                --filter status=running 2>/dev/null | grep -q .; then
            status_color="${grn}"; status_label="running"
        else
            status_color="${ylw}"; status_label="stopped"
        fi
        printf "  %s%-24s%s [%s%s%s]\n" \
            "${cyn}" "$dir_name" "${rst}" \
            "${status_color}" "$status_label" "${rst}"
        (( found++ )) || true
    done < <(find "$stacks_dir" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ $found -eq 0 ]] && log WARN "No stacks found in $stacks_dir"
}

stack_ps() {
    # Formatted, colorized container list sourced directly from docker/podman
    local engine; engine="${csm_cmd%% *}"   # "docker" or "podman"
    {
        printf "%sCONTAINER ID  NAME  STATUS  PORTS%s\n" "${bld}" "${rst}"
        $engine ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | \
        sort -k2,2 | \
        awk 'BEGIN { FS="\t"; OFS="\t" } {
            gsub(/0\.0\.0\.0:/, "", $4)
            gsub(/, *\[::\]:[^ ]*/, "", $4)
            gsub(/->[0-9]+\/[a-z]+/, "", $4)
            print
        }'
    } | column -ts $'\t' | sed -E "
        1 s/^.*$/${bld}&${rst}/
        2,\$ s/^([^ ]+ +)([^ ]+)/\1${cyn}\2${rst}/
        s/unhealthy/${red}&${rst}/g
        s/\bhealthy\b/${grn}&${rst}/g
        s/([0-9]+\/[a-z]+)/${blu}\1${rst}/g
    "
}

stack_status() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    $csm_cmd -f "$f" ps
}

stack_validate() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    if $csm_cmd -f "$f" config -q 2>&1; then
        log PASS "Config valid: $f"
    else
        die "Config invalid: $f"
    fi
}

stack_inspect() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    log INFO "Inspecting stack '$stack_name'..."
    $csm_cmd -f "$f" config
}

stack_logs() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    local lines="${2:-50}"
    $csm_cmd -f "$f" logs -f --tail="$lines"
}

stack_cd() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found at $stack_dir"
    cd "$stack_dir"
}

net_info() {
    local action="${1:-list}"
    local engine; engine="${csm_cmd%% *}"
    case "$action" in
        list)
            printf "%s%-30s %-10s %-10s %s%s\n" \
                "${bld}" "NAME" "DRIVER" "SCOPE" "ID" "${rst}"
            $engine network ls \
                --format "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}" | \
                sort | column -ts $'\t'
            ;;
        host)
            printf "Host IP : %s\n" \
                "$(curl -fsSL ifconfig.me 2>/dev/null || echo 'unavailable')"
            ;;
        inspect)
            local net="${2:-${csm_net_name}}"
            $engine network inspect "$net"
            ;;
        *)
            log FAIL "Unknown net action: $action  (use: list | host | inspect [name])"
            return 1
            ;;
    esac
}

# =============================================================================
# 7. CONFIG MANAGEMENT
# =============================================================================

manage_configs() {
    local action="${1:-show}"
    shift || true
    case "$action" in
        show)
            log INFO "Active configuration:"
            printf "  %-28s = %s\n" \
                "stacks_dir"      "$stacks_dir"      \
                "csm_backup"   "$csm_backup"   \
                "csm_common"   "$csm_common"   \
                "csm_configs"  "$csm_configs"  \
                "csm_secrets"  "$csm_secrets"  \
                "csm_net_name" "$csm_net_name" \
                "csm_cmd"  "${csm_cmd:-<not yet detected>}"
            ;;
        edit)
            local ucfg="${csm_configs}/user.conf"
            [[ ! -f "$ucfg" ]] && { mkdir -p "$csm_configs"; touch "$ucfg"; }
            "${EDITOR:-vi}" "$ucfg"
            ;;
        reload)
            load_config
            log PASS "Configuration reloaded."
            ;;
        *)
            log FAIL "Unknown config action: $action  (use: show | edit | reload)"
            return 1
            ;;
    esac
}

# =============================================================================
# 8. TEMPLATE MANAGEMENT  (stubs — expand as needed)
# =============================================================================

manage_templates() {
    log WARN "The 'templates' command is not yet implemented."
    log WARN "When released, it will list available templates from"
    log WARN "https://codeberg.com/techtinker/homelab and allow you to"
    log WARN "download and run a template to install an app stack."
    # local action="${1:-list}"
    # shift || true
    # case "$action" in
    #     list)
    #         local tdir="${csm_template}"
    #         [[ -d "$tdir" ]] || { log WARN "No templates directory: $tdir"; return 0; }
    #         log INFO "Available templates:"
    #         find "$tdir" -mindepth 1 -maxdepth 1 -type d | sort | \
    #             while IFS= read -r t; do
    #                 printf "  %s%s%s\n" "${cyn}" "$(basename "$t")" "${rst}"
    #             done
    #         ;;
    #     add|remove|update)
    #         log WARN "template $action: not yet implemented."
    #         ;;
    #     *)
    #         log FAIL "Unknown template action: $action  (use: list | add | remove | update)"
    #         return 1
    #         ;;
    # esac
}

# =============================================================================
# 9. HELP
# =============================================================================

show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) v${CSM_VERSION}${rst}

${bld}Usage:${rst} csm <command> [<stack-name>] [options]

${bld}Stack Lifecycle:${rst}
    c  | create   <n>           Create a new stack directory + compose scaffold
    m  | modify   <n>           Open compose.yml in \$EDITOR
    rm | remove   <n>           Stop and remove stack dir (prompts)
    dt | delete   <n>           Stop and PERMANENTLY delete stack + all data (prompts)
    bu | backup   <n>           Tar-gz the stack directory to .backup/

${bld}Stack Operations:${rst}
    u  | up       <n>           Start a stack  (compose up -d)
    d  | down     <n>           Stop a stack   (compose down)
    b  | bounce   <n>           Stop then start (full recreate)
    r  | restart  <n>           Restart containers in-place (no recreate)
    ud | update   <n>           Pull latest images then restart

${bld}Information:${rst}
    l  | list                   List all stacks with running state
    s  | status   <n>           Show compose ps output for a stack
    v  | validate <n>           Validate compose.yml syntax
    g  | logs     <n> [lines]   Follow logs (default: last 50 lines)
    cd            <n>           cd into the stack directory
    ps                          List all containers (formatted)
    net           <action>      Network info: list | host | inspect [name]

${bld}Config:${rst}
    cfg | config  show | edit | reload

${bld}Options:${rst}
    -h | --help            Show this help
    -V | --version         Show version
EOF
}

# =============================================================================
# 10. COMMAND DISPATCHER
# =============================================================================

main() {
    load_config
    validate_config || true
    detect_compose_command

    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { show_help; exit 0; }
    shift || true

    case "$cmd" in
        -h|--help)             show_help;                  exit 0 ;;
        -V|--version)          echo "CSM v${CSM_VERSION}"; exit 0 ;;
        c|create)              stack_create     "$@" ;;
        m|modify)              stack_modify     "$@" ;;
        rm|remove)             stack_remove     "$@" ;;
        dt|delete)             stack_delete     "$@" ;;
        bu|backup)             stack_backup     "$@" ;;
        u|up|start)            stack_start      "$@" ;;
        d|dn|down|stop)        stack_stop       "$@" ;;
        b|bounce|rc|recreate)  stack_bounce     "$@" ;;
        r|rs|restart)          stack_restart    "$@" ;;
        ud|update)             stack_update     "$@" ;;
        l|ls|list)             stack_list            ;;
        s|status)              stack_status     "$@" ;;
        v|validate)            stack_validate   "$@" ;;
        g|logs)                stack_logs       "$@" ;;
        cd)                    stack_cd         "$@" ;;
        ps)                    stack_ps              ;;
        net)                   net_info         "$@" ;;
        t|template)            manage_templates "$@" ;;
        cfg|config)            manage_configs   "$@" ;;
        *) log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
