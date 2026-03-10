#!/bin/bash
# =============================================================================
# File: csm_functions.sh
# Container Stack Manager – Core Function Library
# Sourced by csm.sh; not executed directly.
# =============================================================================

set -uo pipefail
umask 0007

# =============================================================================
# 1. COLOR / LOGGING  (re-declared here so the lib is self-contained when
#    sourced by tools other than csm.sh)
# =============================================================================

_safe_tput() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

color_setup() {
    if [[ -t 1 ]]; then
        red=$(_safe_tput setaf 1); grn=$(_safe_tput setaf 2)
        ylw=$(_safe_tput setaf 3); blu=$(_safe_tput setaf 4)
        prp=$(_safe_tput setaf 5); cyn=$(_safe_tput setaf 6)
        wht=$(_safe_tput setaf 7); blk=$(_safe_tput setaf 0)
        bld=$(_safe_tput bold);    uln=$(_safe_tput smul)
        rst=$(_safe_tput sgr0)
    else
        red="" grn="" ylw="" blu="" prp="" cyn="" wht="" blk=""
        bld="" uln="" rst=""
    fi
}
color_setup

log() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        FAIL) printf "%s FAIL  >> %s%s\n" "${red}${bld}" "${message}" "${rst}" >&2 ;;
        WARN) printf "%s WARN  >> %s%s\n" "${ylw}${bld}" "${message}" "${rst}" >&2 ;;
        INFO) printf "%s INFO  >> %s%s\n" "${cyn}${bld}" "${message}" "${rst}" ;;
        DONE) printf "%s DONE  >> %s%s\n" "${grn}${bld}" "${message}" "${rst}" ;;
        *)    printf "%s DBG   >> %s%s\n" "${blu}${bld}" "${message}" "${rst}" ;;
    esac
}

die() { log FAIL "$1"; exit 1; }

# =============================================================================
# 2. CONFIGURATION
# =============================================================================

# Built-in defaults — all overridable by default.conf / user.conf / env vars
declare -A _csm_defaults=(
    [CSM_ROOT_DIR]="/srv/stacks"
    [CSM_BACKUP_DIR]="/srv/stacks/backup"
    [CSM_COMMON_DIR]="/srv/stacks/common"
    [CSM_STACKS_DIR]="/srv/stacks/stacks"
    [CSM_CONFIGS_DIR]="/srv/stacks/common/configs"
    [CSM_SECRETS_DIR]="/srv/stacks/common/secrets"
    [CSM_NETWORK_NAME]="csm_network"
    [CSM_STACK_FILE]="compose.yml"
    [CSM_STACK_CONF]=".env"
)

# Apply defaults for any variable not already set in the environment
_apply_defaults() {
    for key in "${!_csm_defaults[@]}"; do
        [[ -z "${!key:-}" ]] && export "$key"="${_csm_defaults[$key]}"
    done
}

load_config() {
    _apply_defaults
    local cfg_files=(
        "${CSM_CONFIGS_DIR}/default.conf"
        "${CSM_CONFIGS_DIR}/user.conf"
        "${HOME}/.config/csm/config"
    )
    for f in "${cfg_files[@]}"; do
        [[ -f "$f" ]] && source "$f"
    done
    _apply_defaults   # re-apply so conf-file vars expand correctly
}

validate_config() {
    local errors=0
    for dir in "$CSM_ROOT_DIR" "$CSM_BACKUP_DIR" "$CSM_COMMON_DIR" "$CSM_STACKS_DIR"; do
        if [[ ! -d "$dir" ]]; then
            log WARN "Directory not found: $dir  (run 'csm-install.sh' to create it)"
            (( errors++ )) || true
        fi
    done
    return $errors
}

detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        compose_cmd="docker compose"
    elif podman compose version >/dev/null 2>&1; then
        compose_cmd="podman compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        die "'docker-compose' v1 is unsupported. Please upgrade to 'docker compose' (v2)."
    else
        die "No supported container runtime found. Install Docker or Podman."
    fi
    export compose_cmd
}

# =============================================================================
# 3. INTERNAL HELPERS
# =============================================================================

_require_name() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Stack name is required."
    echo "$name"
}

get_stack_dir() {
    local name
    name="$(_require_name "${1:-}")"
    echo "${CSM_STACKS_DIR}/${name}"
}

_require_stack() {
    # Returns compose file path, exits if missing
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(get_stack_dir "$name")/${CSM_STACK_FILE:-compose.yml}"
    [[ -f "$compose_file" ]] || die "Compose file not found: $compose_file"
    echo "$compose_file"
}

_confirm() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [y/N]: ${rst}" _reply
    [[ "${_reply,,}" == "y" ]]
}

# =============================================================================
# 4. STACK LIFECYCLE
# =============================================================================

create_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local stack_dir
    stack_dir="$(get_stack_dir "$name")"

    [[ -d "$stack_dir" ]] && die "Stack '$name' already exists at $stack_dir"

    mkdir -p "${stack_dir}/appdata"

    cat > "${stack_dir}/compose.yml" <<EOF
networks:
  default:
    external:
      name: ${CSM_NETWORK_NAME:-csm_network}

services:
  # Add your service definitions here
  # example:
  #   image: nginx:alpine
  #   restart: unless-stopped
EOF

    touch "${stack_dir}/.env"
    log DONE "Stack '${name}' created at ${stack_dir}"
}

modify_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    "${EDITOR:-vi}" "$compose_file"
}

remove_stack() {
    # Stops stack, removes stack dir, preserves appdata outside stack dir
    local name
    name="$(_require_name "${1:-}")"
    local stack_dir
    stack_dir="$(get_stack_dir "$name")"
    [[ -d "$stack_dir" ]] || die "Stack '$name' not found at $stack_dir"

    _confirm "Remove stack '$name'? (appdata inside $stack_dir will also be removed)" || {
        log INFO "Cancelled."; return 0
    }
    down_stack "$name" 2>/dev/null || true
    rm -rf "$stack_dir"
    log DONE "Stack '$name' removed."
}

delete_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local stack_dir
    stack_dir="$(get_stack_dir "$name")"
    [[ -d "$stack_dir" ]] || die "Stack '$name' not found at $stack_dir"

    # Safety: never allow deleting root or stacks dir itself
    [[ "$stack_dir" == "/" || "$stack_dir" == "$CSM_STACKS_DIR" ]] && \
        die "Safety guard: refusing to delete $stack_dir"

    log WARN "This will PERMANENTLY delete '$name' and ALL its data."
    _confirm "Confirm DELETE of $stack_dir?" || { log INFO "Cancelled."; return 0; }

    down_stack "$name" 2>/dev/null || true
    rm -rf "$stack_dir"
    log DONE "Stack '$name' deleted."
}

backup_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local stack_dir
    stack_dir="$(get_stack_dir "$name")"
    [[ -d "$stack_dir" ]] || die "Stack '$name' not found."

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${CSM_BACKUP_DIR}/${name}"
    backup_file="${backup_dir}/${name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"
    log INFO "Creating backup: $backup_file"
    tar -czf "$backup_file" -C "$CSM_STACKS_DIR" "$name"
    log DONE "Backup complete: $backup_file"
}

# =============================================================================
# 5. STACK OPERATIONS
# =============================================================================

up_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    $compose_cmd -f "$compose_file" up -d \
        && log DONE "Stack '$name' is up." \
        || die "Failed to start stack '$name'."
}

down_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    $compose_cmd -f "$compose_file" down \
        && log DONE "Stack '$name' stopped." \
        || die "Failed to stop stack '$name'."
}

restart_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    log INFO "Restarting stack '$name'..."
    $compose_cmd -f "$compose_file" restart \
        && log DONE "Stack '$name' restarted."
}

bounce_stack() {
    local name
    name="$(_require_name "${1:-}")"
    log INFO "Bouncing (down then up) stack '$name'..."
    down_stack "$name"
    up_stack   "$name"
}

update_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    log INFO "Pulling latest images for '$name'..."
    $compose_cmd -f "$compose_file" pull
    $compose_cmd -f "$compose_file" up -d \
        && log DONE "Stack '$name' updated."
}

# =============================================================================
# 6. INFORMATION
# =============================================================================

list_stacks() {
    if [[ ! -d "$CSM_STACKS_DIR" ]]; then
        die "Stacks directory not found: $CSM_STACKS_DIR"
    fi
    log INFO "Stacks in ${CSM_STACKS_DIR}:"
    local found=0
    while IFS= read -r -d '' stack_dir; do
        local sname status_color status_label
        sname="$(basename "$stack_dir")"
        # Quick running-state check (best-effort; won't abort on error)
        if $compose_cmd -f "${stack_dir}/${CSM_STACK_FILE:-compose.yml}" ps --services --filter status=running \
               2>/dev/null | grep -q .; then
            status_color="${grn}"; status_label="running"
        else
            status_color="${ylw}"; status_label="stopped"
        fi
        printf "  %s%-20s%s  [%s%s%s]\n" \
            "${cyn}" "$sname" "${rst}" \
            "${status_color}" "$status_label" "${rst}"
        (( found++ )) || true
    done < <(find "$CSM_STACKS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    [[ $found -eq 0 ]] && log WARN "No stacks found."
}

status_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    $compose_cmd -f "$compose_file" ps
}

validate_stack() {
    local name
    name="$(_require_name "${1:-}")"
    local compose_file
    compose_file="$(_require_stack "$name")"
    if $compose_cmd -f "$compose_file" config -q 2>&1; then
        log DONE "Config valid: $compose_file"
    else
        die "Config invalid: $compose_file"
    fi
}

# =============================================================================
# 7. TEMPLATE MANAGEMENT  (stub – expand as needed)
# =============================================================================

manage_templates() {
    local action="${1:-list}"
    shift || true
    case "$action" in
        list)   _templates_list ;;
        add)    _templates_add "$@" ;;
        remove) _templates_remove "$@" ;;
        update) _templates_update ;;
        *)      log FAIL "Unknown template action: $action"; return 1 ;;
    esac
}

_templates_list() {
    local tdir="${CSM_TEMPLATES_DIR:-${CSM_COMMON_DIR}/templates}"
    if [[ ! -d "$tdir" ]]; then
        log WARN "Templates directory not found: $tdir"; return 0
    fi
    log INFO "Available templates:"
    find "$tdir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | \
        while read -r t; do printf "  %s%s%s\n" "${cyn}" "$t" "${rst}"; done
}

_templates_add()    { log WARN "template add: not yet implemented."; }
_templates_remove() { log WARN "template remove: not yet implemented."; }
_templates_update() { log WARN "template update: not yet implemented."; }

# =============================================================================
# 8. CONFIG MANAGEMENT
# =============================================================================

manage_configs() {
    local action="${1:-show}"
    shift || true
    case "$action" in
        show)
            log INFO "Active configuration:"
            for key in CSM_ROOT_DIR CSM_BACKUP_DIR CSM_COMMON_DIR \
                       CSM_STACKS_DIR CSM_CONFIGS_DIR CSM_SECRETS_DIR \
                       CSM_NETWORK_NAME CSM_STACK_FILE; do
                printf "  %-25s = %s\n" "$key" "${!key:-<unset>}"
            done
            ;;
        edit)
            local ucfg="${CSM_CONFIGS_DIR}/user.conf"
            [[ ! -f "$ucfg" ]] && touch "$ucfg"
            "${EDITOR:-vi}" "$ucfg"
            ;;
        reload)
            load_config
            log DONE "Configuration reloaded."
            ;;
        *)
            log FAIL "Unknown config action: $action  (use: show | edit | reload)"
            return 1
            ;;
    esac
}
