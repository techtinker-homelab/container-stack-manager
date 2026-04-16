#!/bin/bash
# =============================================================================
# Container Stack Manager (CSM)
# A unified container stack management tool supporting Docker and Podman
# Author:  Drauku
# License: MIT
# =============================================================================
# Repository file layout (pre-install):
#   ./<repo>/
#   ├── csm.sh              ← Main runtime script (symlinked to /usr/local/bin/csm during install)
#   ├── csm-install.sh      ← One-shot installer (run once; sets up the environment)
#   ├── example.conf        ← Default configuration values (copied as default.conf during install)
#   ├── example.conf        ← Example global environment template
#   └── README.md           ← Project description and instructions for installation and use.
#
# Installed layout:
#   /srv/stacks/                    ← CSM root directory
#   ├── .backups/
#   │  └── <stack>/
#   │     └── <stack>-YYYYMMDD_HHMMSS.tar.gz  ← backup file for each stack
#   ├── .configs/
#   │  ├── csm.sh                   ← main CSM script containing all helper scripts
#   │  ├── default.conf             ← default configuration variables
#   │  ├── local-compose.yml        ← example compose.yml for "local" Docker & Podman
#   │  ├── swarm-compose.yml        ← example compose.yml for Docker Swarm only
#   │  └── user.conf                ← user overrides (optional)
#   ├── .secrets/
#   │  ├── .local.env               ← Podman and Docker Local variables
#   │  ├── .swarm.env               ← Docker Swarm specific variables
#   │  ├── example.env              ← bare bones example .env variables
#   │  └── <variable_name>.secret   ← one secret file per secret variable
#   ├── .modules/
#   │  └── <stack>/                 ← descriptive name of the stack
#   │     ├── compose.yml           ← pre-made compose.yml tailored to work with CSM
#   │     └── example.env           ← variables required for this specific compose.yml
#   └── <stack>/
#      ├── .env                     ← symlinked to the .scope.env / custom .env
#      ├── compose.yml              ← stack containers configuration file
#      └── appdata/                 ← stack appdata directory for each container
# =============================================================================

set -euo pipefail

# =============================================================================
# INITIAL VARIABLE DEFINITIONS
# =============================================================================
readonly script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "${script_dir}/csm.ini"

csm_debug="1" # set to "1" to display debug step messages
csm_cmd=""    # set by _detect_command
scope=""      # set by _detect_scope

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_dirs="775"   # directories:  rwxrwxr-x
readonly mode_exec="770"   # executables:  rwxrwx---
readonly mode_conf="660"   # config files: rw-rw----
readonly mode_auth="600"   # secrets:      rw-------

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
    printf "%s %-4s >> %s%s\n" "${color}${bld}" "${level}" "${message}" "${rst}" >&2
    if [[ "$level" == "EXIT" ]]; then exit 1; fi
}

_check_cmd() {
    if ! command -v "$csm_cmd" >/dev/null 2>&1; then
        _log EXIT "No $csm_cmd runtime found. Install Docker or Podman first."
    fi
}

_check_dir() {
    local dir="${1:-}"
    if [[ ! -d "$dir" ]]; then return 0; fi # Skip if directory doesn't exist

    local owner; owner=$(stat -c '%U' "$dir" 2>/dev/null || stat -f '%Su' "$dir")
    local perms; perms=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir")

    # Safe if owned by current user or root AND not world-writable (last digit < 2)
    if [[ "$owner" == "$USER" || "$owner" == "root" ]] && [[ "${perms: -1}" < "2" ]]; then
        return 0
    fi
    return 1
}

_confirm_yes() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    if [[ -z "${reply}" || "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1 so the script doesn't crash
}

_confirm_no() {
    if [[ "$force_install" == 1 ]]; then return 0; fi
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" reply
    if [[ "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1
}

# =============================================================================
# CONFIGURATION
# =============================================================================

_detect_command() {
    _log STEP "_detect_command: checking for docker compose..."
    if docker compose version >/dev/null 2>&1; then
        csm_cmd="docker"
        _log STEP "_detect_command: using docker"
    elif podman compose version >/dev/null 2>&1; then
        csm_cmd="podman"
        _log STEP "_detect_command: using podman"
    elif command -v docker-compose >/dev/null 2>&1; then
        _log EXIT "'docker-compose' v1 is unsupported. Upgrade to 'docker compose' (v2)."
    else
        _log EXIT "No supported container runtime found. Install Docker or Podman."
    fi
}

_detect_swarm() {
    _log STEP "_detect_swarm: csm_cmd=$csm_cmd"
    _check_cmd
    if [[ "$csm_cmd" == "podman" ]]; then
        _log STEP "_detect_swarm: podman detected, skipping"
        return 1
    fi
    local state
    state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
    _log STEP "_detect_swarm: swarm state=$state"
    if [[ "$state" == "active" ]]; then return 0; fi
    return 1 # Explicit return
}

_detect_scope() {
    local stack_name="${1:-}"
    local stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_detect_scope: stack_name=$stack_name, stack_dir=$stack_dir"
    _check_cmd

    # Podman has no swarm — always local
    if [[ "$csm_cmd" == "podman" ]]; then
        _log STEP "_detect_scope: podman -> local"; scope="local"
        return 0 # Changed from return to return 0
    fi

    # Explicit marker files override auto-detect


    if [[ -f "${stack_dir}/.local" ]]; then
        _log STEP "_detect_scope: .local marker found -> local"; scope="local"
        return 0
    fi
    if [[ -f "${stack_dir}/.swarm" ]]; then
        _log STEP "_detect_scope: .swarm marker found -> swarm"; scope="swarm"
        return 0
    fi

    # Check swarm status, otherwise set local scope
    if _detect_swarm; then
        # Swarm is active, now check if stack is deployed
        if docker stack ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qw "$stack_name"; then
            _log STEP "_detect_scope: stack found in swarm ls -> swarm"
            scope="swarm"
            return 0
        fi
        if docker network inspect ingress >/dev/null 2>&1; then
            _log STEP "_detect_scope: ingress network found -> swarm"
            scope="swarm"
            return 0
        fi
    else
        _log STEP "_detect_scope: swarm inactive -> local"; scope="local"
        return 0
    fi

    # Default fallback
    _log STEP "_detect_scope: default -> local"
    scope="local"
    return 0
}

_load_config() {
    _log STEP "_load_config: loading config files..."
    csm_configs="${script_dir}/.configs"
    local config_paths=(
        "${csm_configs}"
        "${HOME}/.config/csm"
    )

    for dir in "${config_paths[@]}"; do
        if _check_dir "$dir"; then
            for f in "$dir"/*.conf "$dir"/user.conf; do
                if [[ -f "$f" ]]; then source "$f"; fi
            done
        else
            _log WARN "Skipping unsafe config directory: $dir"
        fi
    done

    for f in \
        "${csm_configs}"/*.conf \
        "${csm_configs}"/user.conf \
        "${HOME}"/.config/csm/*.conf \
        "${HOME}"/.config/csm/user.conf
    do
        if [[ -f "$f" ]]; then
            _log STEP "_load_config: sourcing $f"
            source "$f"
        else
            _log STEP "_load_config: not found $f"
        fi
    done

    csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
    csm_backups="${CSM_BACKUPS_DIR:-${csm_dir}/.backups}"
    csm_configs="${CSM_CONFIGS_DIR:-${csm_dir}/.configs}"
    csm_secrets="${CSM_SECRETS_DIR:-${csm_dir}/.secrets}"
    csm_modules="${CSM_MODULES_DIR:-${csm_dir}/.modules}"

    csm_net_name="${CSM_NETWORK_NAME:-csm_network}"
    csm_gid="${CSM_STACKS_GID:-$(id -g)}"
    csm_uid="${CSM_STACKS_UID:-$(id -u)}"
    csm_group=$(id -gn "$csm_uid" 2>/dev/null || getent group "$csm_gid" | cut -d: -f1)
    csm_owner=$(id -un "$csm_uid" 2>/dev/null || getent passwd "$csm_uid" | cut -d: -f1)

    csm_version=${CSM_VERSION:-unknown}

    _log STEP "_load_config: csm_dir=$csm_dir, csm_cmd will be detected next"
}

_validate_config() {
    local errors=0
    _log STEP "_validate_config: checking directories..."
    for dir in "$csm_dir" "$csm_backups"; do
        if [[ ! -d "$dir" ]]; then
            _log WARN "Directory not found: $dir  (run csm-install.sh to repair)"
            (( errors++ )) || true
        else
            _log STEP "_validate_config: $dir exists"
        fi
    done
    _log STEP "_validate_config: errors=$errors"
    return $errors
}

_validate_permissions() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_validate_permissions: checking $stack_dir"
    if [[ ! -d "$stack_dir" ]]; then return 0; fi
    local perm
    perm=$(stat -c '%a' "$stack_dir" 2>/dev/null || stat -f '%Lp' "$stack_dir")
    _log STEP "_validate_permissions: got perm=$perm, expected 770"
    if [[ "$perm" != "770" ]]; then
        _log WARN "Incorrect permissions on $stack_dir (got $perm, expected 770)"
        _log WARN "Fix manually: chmod 770 \"$stack_dir\" && find \"$stack_dir\" -type f -exec chmod 660 {} \\;"
    fi
}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_require_name() {
    if [[ ! -n "${1:-}" ]]; then _log EXIT "Stack name is required."; fi
    _log STEP "_require_name: ${1:-}"
    echo "${1:-}"
}

_get_stack_dir() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local dir="${csm_dir}/${stack_name}"
    _log STEP "_get_stack_dir: $dir"
    echo "$dir"
}

_require_compose_file() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f="${csm_dir}/${stack_name}/compose.yml"
    _log STEP "_require_compose_file: checking $f"
    if [[ -f "$f" ]]; then _log EXIT "Compose file not found: $f"; fi
    echo "$f"
}

_fix_permissions() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_fix_permissions: fixing $stack_dir"
    find "$stack_dir" -type f -exec chmod 660 {} \;
    find "$stack_dir" -type d -exec chmod 770 {} \;
}

_del_safe() {
    local stack_name="${1:-}"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_del_safe: name=$stack_name, dir=$stack_dir"
    _check_cmd

    if [[ ! -d "$stack_dir" ]]; then return 0; fi
    if [[ "$stack_dir" == "/" || "$stack_dir" == "$csm_dir" ]]; then
        _log EXIT "Safety guard: refusing to delete $stack_dir"
    fi

    if [[ -f "${stack_dir}/compose.yml" ]]; then
        _log STEP "_del_safe: compose.yml found, detecting scope and stopping..."
        _detect_scope "$stack_name"
        _log STEP "_del_safe: scope=$scope"
        case "$scope" in
            swarm) docker stack rm "$stack_name" 2>/dev/null || true ;;
            local) $csm_cmd compose -f "${stack_dir}/compose.yml" stop 2>/dev/null || true ;;
        esac
    fi

    _log STEP "_del_safe: running rm -rf $stack_dir"
    rm -rf "$stack_dir"
    _log PASS "Stack '$stack_name' deleted."
}

# =============================================================================
# STACK LIFECYCLE (public)
# =============================================================================

stack_create() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local user_scope="${2:-}"
    local target_scope="local"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"

    # Determine Target Scope
    _log STEP "stack_create: determining target scope..."
    if [[ -n "$user_scope" ]]; then
        target_scope="$user_scope"
    elif docker network inspect ingress >/dev/null 2>&1; then
        _log STEP "stack_create: ingress network found, defaulting to swarm"
        target_scope="swarm"
    fi

    local tmpl_compose="$csm_configs/${target_scope}-compose.yml"
    local tmpl_env="$csm_configs/.${target_scope}.env"

    _log STEP "stack_create: name=$stack_name, dir=$stack_dir, scope=$target_scope"
    if [[ -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' already exists at $stack_dir"; fi

    _log STEP "stack_create: creating directories..."
    install -o "$csm_uid" -g "$csm_gid" -m "$mode_dirs" -d "$stack_dir"/appdata
    install -o "$csm_uid" -g "$csm_gid" -m "$mode_dirs" -d "$stack_dir"

    # Handle Compose File
    if [[ -f "$tmpl_compose" ]]; then
        _log STEP "stack_create: copying template $tmpl_compose"
        install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$tmpl_compose" "$stack_dir/compose.yml"

        # Inject the dynamic network name into the static template
        sed -i "s/CSM_NETWORK_PLACEHOLDER/${csm_net_name}/g" "$stack_dir/compose.yml"
    else
        _log WARN "Template not found: $tmpl_compose. Falling back to internal boilerplate."
        cat > "${stack_dir}/compose.yml" <<EOF
networks:
  default:
    external:
      name: ${csm_net_name}

services:
  # Add your service definitions here
EOF
    fi

    # Handle Env File
    if [[ -f "$tmpl_env" ]]; then
        _log STEP "stack_create: copying env template $tmpl_env"
        install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$tmpl_env" "$stack_dir/.env"
    else
        _log STEP "stack_create: no template found, creating empty .env"
        : > "${stack_dir}/.env"
    fi

    _log STEP "stack_create: fixing permissions"
    _fix_permissions "$stack_name"

    # Lock in the scope with a marker file
    _log STEP "stack_create: dropping .$target_scope marker file"
    touch "$stack_dir/.$target_scope"

    _log PASS "Stack '$stack_name' created at ${stack_dir} [Scope: $target_scope]"
}

stack_rename() {
    local old_name; old_name="$(_require_name "${1:-}")"
    local new_name; new_name="$(_require_name "${2:-}")"
    local old_dir; old_dir="$(_get_stack_dir "$old_name")"
    local new_dir; new_dir="$(_get_stack_dir "$new_name")"

    _log STEP "stack_rename: renaming '$old_name' -> '$new_name'"
    if [[ ! -d "$old_dir" ]]; then _log EXIT "Stack '$old_name' not found at $old_dir"; fi
    if [[ -d "$new_dir" ]]; then _log EXIT "Stack '$new_name' already exists at $new_dir"; fi

    _log STEP "stack_rename: moving $old_dir -> $new_dir"
    mv "$old_dir" "$new_dir"
    _log PASS "Stack '$old_name' renamed to '$new_name'."
}

stack_edit() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_edit: opening $f with ${EDITOR:-vi}"
    "${EDITOR:-vi}" "$f"
}

stack_backup() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    stack_name="${stack_name%/}"

    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found."; fi

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${csm_backups}/${stack_name}"
    backup_file="${backup_dir}/${stack_name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"

    _log STEP "stack_backup: creating $backup_file"
    if tar -czf "$backup_file" -C "$csm_dir" "$stack_name"; then
        # Integrity Check: Verify the archive can be read
        if tar -tzf "$backup_file" >/dev/null 2>&1; then
            _log PASS "Backup complete and verified: $backup_file"
        else
            _log FAIL "Backup created but failed integrity check: $backup_file"
            return 1
        fi
    else
        _log FAIL "Backup failed during creation: $backup_file"
        return 1
    fi
}

stack_remove() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "stack_remove: name=$stack_name, dir=$stack_dir"
    _check_cmd
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found at $stack_dir"; fi

    if ! _confirm_no "Remove stack '$stack_name'? (all running stack containers will be removed)"; then
        _log INFO "Cancelled."
        return 0
    fi

    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_remove: detecting scope..."
    _detect_scope "$stack_name"
    _log STEP "stack_remove: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_remove: running docker stack rm $stack_name"
            docker stack rm "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' removed." \
                || _log EXIT "Failed to remove Swarm stack '$stack_name'."
            ;;
        local)
            local containers
            _log STEP "stack_remove: checking for running containers..."
            containers=$($csm_cmd compose -f "$f" ps -q 2>/dev/null) || true
            if [[ -n "$containers" ]]; then
                _log STEP "stack_remove: removing containers..."
                $csm_cmd compose -f "$f" rm --stop --force
            fi
            _log PASS "Local stack '$stack_name' containers removed."
            ;;
    esac
}

stack_delete() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "stack_delete: name=$stack_name, dir=$stack_dir"
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found at $stack_dir"; fi

    _log WARN "This will PERMANENTLY delete '$stack_name' and ALL associated appdata."
    if ! _confirm_no "Confirm DELETE of $stack_dir?"; then _log INFO "Cancelled."; return 0; fi

    _log STEP "stack_delete: calling _del_safe"
    _del_safe "$stack_name"
}

stack_recreate() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "stack_recreate: name=$stack_name, dir=$stack_dir"
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found."; fi

    _log WARN "This will destroy the current stack directory and create a fresh one."
    if ! _confirm_no "Confirm RECREATE for '$stack_name'?"; then _log INFO "Cancelled."; return 0; fi

    _log STEP "stack_recreate: calling _del_safe then stack_create"
    _del_safe "$stack_name"
    stack_create "$stack_name"
}

stack_purge() {
    local target_stacks=("$@")

    if [[ ${#target_stacks[@]} -eq 0 ]]; then
        _log WARN "No stacks specified. Gathering ALL stacks for purge."
        if ! _confirm_no "Are you sure you want to iterate through ALL stacks?"; then
            _log INFO "Cancelled."
            return 0
        fi
        while IFS= read -r -d '' d; do
            target_stacks+=("$(basename "$d")")
        done < <(find "$csm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
    fi

    for stack in "${target_stacks[@]}"; do
        local d; d="$(_get_stack_dir "$stack")"
        if [[ ! -d "$d" ]]; then continue; fi

        _log STEP "Evaluating: $stack"

        if ! _confirm_no "Permanently delete stack '$stack'?"; then
            _log INFO "Skipping $stack."
            continue
        fi

        if _confirm_yes "Backup '$stack' before deletion?"; then
            stack_backup "$stack"
        fi

        if _confirm_no "Final check: DESTROY '$stack'?"; then
            _del_safe "$stack"
        else
            _log INFO "Skipped $stack at the final step."
        fi
    done

    _log PASS "Purge operations complete."
}

# =============================================================================
# STACK OPERATIONS (public)
# =============================================================================

stack_up() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_up: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_up: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_up: running docker stack deploy -c $f $stack_name"
            docker stack deploy -c "$f" "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' deployed." \
                || _log EXIT "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_up: running $csm_cmd compose -f $f up -d --remove-orphans"
            $csm_cmd compose -f "$f" up -d --remove-orphans \
                && _log PASS "Stack '$stack_name' is up." \
                || _log EXIT "Failed to bring up Local stack '$stack_name'."
            ;;
    esac
}

stack_down() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_down: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_down: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_down: running docker stack rm $stack_name"
            docker stack rm "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' brought down (removed)." \
                || _log EXIT "Failed to bring down Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_down: running $csm_cmd compose -f $f down"
            $csm_cmd compose -f "$f" down \
                && _log PASS "Stack '$stack_name' brought down." \
                || _log EXIT "Failed to bring down Local stack '$stack_name'."
            ;;
    esac
}

stack_bounce() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_bounce: name=$stack_name, compose=$f"
    _detect_scope "$stack_name"
    _log STEP "stack_bounce: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_bounce: running docker stack deploy -c $f $stack_name"
            docker stack deploy -c "$f" "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' re-deployed." \
                || _log EXIT "Failed to re-deploy Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_bounce: calling stack_down then stack_up"
            stack_down "$stack_name"
            stack_up   "$stack_name"
            ;;
    esac
}

stack_start() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_start: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_start: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_start: running docker stack deploy -c $f $stack_name"
            docker stack deploy -c "$f" "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' deployed." \
                || _log EXIT "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_start: running $csm_cmd compose -f $f start"
            $csm_cmd compose -f "$f" start \
                && _log PASS "Stack '$stack_name' started." \
                || _log EXIT "Failed to start Local stack '$stack_name'."
            ;;
    esac
}

stack_restart() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_restart: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_restart: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_restart: running docker stack deploy -c $f $stack_name"
            docker stack deploy -c "$f" "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' deployed." \
                || _log EXIT "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_restart: running $csm_cmd compose -f $f restart"
            $csm_cmd compose -f "$f" restart \
                && _log PASS "Stack '$stack_name' restarted." \
                || _log EXIT "Failed to restart Local stack '$stack_name'."
            ;;
    esac
}

stack_stop() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_stop: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_stop: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_stop: running docker stack rm $stack_name"
            docker stack rm "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' removed." \
                || _log EXIT "Failed to remove Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_stop: running $csm_cmd compose -f $f stop"
            $csm_cmd compose -f "$f" stop \
                && _log PASS "Stack '$stack_name' stopped." \
                || _log EXIT "Failed to stop Local stack '$stack_name'."
            ;;
    esac
}

stack_update() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_update: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_update: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_update: running docker stack deploy -c $f $stack_name"
            docker stack deploy -c "$f" "$stack_name" \
                && _log PASS "Swarm stack '$stack_name' updated (redeployed)." \
                || _log EXIT "Failed to update Swarm stack '$stack_name'."
            ;;
        local)
            _log STEP "stack_update: running $csm_cmd compose -f $f pull"
            $csm_cmd compose -f "$f" pull
            _log STEP "stack_update: running $csm_cmd compose -f $f up -d"
            $csm_cmd compose -f "$f" up -d \
                && _log PASS "Stack '$stack_name' updated." \
                || _log EXIT "Failed to update Local stack '$stack_name'."
            ;;
    esac
}

# =============================================================================
# SECRETS MANAGEMENT (public)
# =============================================================================

_safe_secret() {
    local secret_file="${1:-}"
    local value="${2-}"
    local old_umask
    local rc

    old_umask="$(umask)"
    umask 077

    if [[ -n "$value" ]]; then
        printf '%s' "$value" > "$secret_file"
    else
        cat > "$secret_file"
    fi
    rc=$?

    umask "$old_umask" || return 1
    (( rc == 0 )) || return "$rc"

    chmod 600 "$secret_file"
}

secret_create() {
    local name="${1:-}"
    local secret_file="${csm_secrets}/${name}.secret"

    _log STEP "secret_create: name=$name, file=$secret_file"
    if [[ ! -n "$name" ]]; then _log EXIT "Secret name is required."; fi

    if [[ ! -d "$csm_secrets" ]]; then
        _log EXIT "The csm_secrets directory does not exist. Unable to create backup secret, exiting."
    fi

    _log STEP "secret_create: checking swarm status..."
    _detect_swarm || _log EXIT "Swarm must be active to create Docker secrets."

    if docker secret inspect "$name" >/dev/null 2>&1; then
        _log EXIT "Docker secret '$name' already exists. Use 'secret-rm' first."
    fi

    if [[ -f "$secret_file" ]]; then
        _log STEP "secret_create: using existing file $secret_file"
        if [[ -L "$secret_file" ]]; then _log EXIT "Refusing symlinked secret file: $secret_file"; fi
        if [[ ! -r "$secret_file" ]]; then _log EXIT "Secret file exists but is not readable: $secret_file"; fi
        local perms="$(stat -c '%a' "$secret_file" 2>/dev/null || stat -f '%Lp' "$secret_file" 2>/dev/null || true)"
        if [[ ! "$perms" == "600" ]]; then _log WARN "Secret file permissions are $perms, expected 600."; fi
        _log STEP "secret_create: running docker secret create $name $secret_file"
        docker secret create "$name" "$secret_file" \
            && _log PASS "Docker secret '$name' created from $secret_file." \
            || _log EXIT "Failed to create Docker secret '$name' from file."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        _log STEP "secret_create: reading from stdin"
        _safe_secret "$secret_file"
        if [[ ! -s "$secret_file" ]]; then
            rm -f "$secret_file"
            _log EXIT "Secret value is required."
        fi

        docker secret create "$name" "$secret_file" \
            && _log PASS "Docker secret '$name' created from stdin (saved to $secret_file)." \
            || { rm -f "$secret_file"; _log EXIT "Failed to create Docker secret '$name'."; }
        return 0
    fi

    _log STEP "secret_create: prompting for value"
    local value=""
    read -r -s -p "Enter secret value for '$name': " value
    printf '\n' >&2
    if [[ ! -n "$value" ]]; then _log EXIT "Secret value is required."; fi

    _safe_secret "$secret_file" "$value"

    _log STEP "secret_create: running docker secret create $name $secret_file"
    docker secret create "$name" "$secret_file" \
        && _log PASS "Docker secret '$name' created from prompt input (saved to $secret_file)." \
        || { rm -f "$secret_file"; _log EXIT "Failed to create Docker secret '$name'."; }

    unset value
}

secret_remove() {
    local name="${1:-}"
    local secret_file="${csm_secrets}/${name}.secret"
    _log STEP "secret_remove: checking swarm status..."
    _detect_swarm || _log EXIT "Swarm must be active to remove Docker secrets."
    _log STEP "secret_remove: name=$name, file=$secret_file"
    if [[ ! -n "$name" ]]; then _log EXIT "Secret name is required."; fi
    if ! _confirm_no "Remove Docker secret '$name' and backup file?"; then
        _log INFO "Cancelled."
        return 0
    fi
    _log STEP "secret_remove: checking swarm status..."
    _detect_swarm || _log EXIT "Swarm must be active to remove Docker secrets."
    if ! docker secret inspect "$name" >/dev/null 2>&1; then
        _log EXIT "Docker secret '$name' not found."
    fi
    _log STEP "secret_remove: running docker secret rm $name"
    docker secret rm "$name" \
        && _log PASS "Docker secret '$name' removed." \
        || _log EXIT "Failed to remove Docker secret '$name' (it may still be attached to a service)."
    if [[ -f "$secret_file" ]]; then
        if [[ -L "$secret_file" ]]; then _log EXIT "Refusing symlinked secret file: $secret_file"; fi
        _log STEP "secret_remove: removing backup file $secret_file"
        rm -f "$secret_file" \
            && _log PASS "Backup secret file removed: $secret_file" \
            || _log WARN "Failed to remove backup secret file: $secret_file"
    fi
}

secret_list() {
    _log STEP "secret_list: checking swarm status..."
    _detect_swarm || _log EXIT "Swarm must be active to manage Docker secrets."
    _log STEP "secret_list: checking swarm status..."
    if ! _detect_swarm; then
        _log EXIT "Swarm must be active to list Docker secrets."
    fi
    _log STEP "secret_list: running docker secret ls"
    docker secret ls --format "table {{.Name}}\t{{.CreatedAt}}\t{{.UpdatedAt}}"
}

# =============================================================================
# INFORMATION (public)
# =============================================================================

stack_list() {
    _log STEP "stack_list: csm_dir=$csm_dir"
    _check_cmd
    if [[ ! -d "$csm_dir" ]]; then _log EXIT "Stacks directory not found: $csm_dir"; fi

    local swarm_active=false
    _detect_swarm && swarm_active=true
    _log STEP "stack_list: swarm_active=$swarm_active"

    local -a valid_stacks=()
    local -a empty_dirs=()

    _log STEP "stack_list: scanning for stacks..."
    while IFS= read -r -d '' stack_dir; do
        local dir_name; dir_name="$(basename "$stack_dir")"
        if [[ -f "${stack_dir}/compose.yml" || -f "${stack_dir}/docker-compose.yml" || -f "${stack_dir}/podman-compose.yml" ]]; then
            valid_stacks+=("$dir_name")
            _log STEP "stack_list: found valid stack: $dir_name"
        else
            empty_dirs+=("$dir_name")
            _log STEP "stack_list: found empty dir: $dir_name"
        fi
    done < <(find "$csm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | sort -z)

    local -a swarm_stacks=()
    if $swarm_active; then
        while IFS= read -r s; do
            if [[ -n "$s" ]]; then swarm_stacks+=("$s"); fi
        done < <(docker stack ls 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    if [[ ${#valid_stacks[@]} -gt 0 ]]; then
        _log INFO "Active stacks in ${csm_dir}:"
        for dir_name in "${valid_stacks[@]}"; do
            local stack_dir="${csm_dir}/${dir_name}"
            local status_color status_label scope_label

            local is_swarm=false
            if $swarm_active; then
                for s in "${swarm_stacks[@]}"; do
                    if [[ "$s" == "$dir_name" && "$(is_swarm)" == "true" ]]; then break; fi
                done
            fi

            if $is_swarm; then
                scope_label="swarm"
                status_color="${grn}"
                status_label="deployed"
            elif $csm_cmd compose -f "${stack_dir}/compose.yml" ps --services \
                --filter status=running 2>/dev/null | grep -q .; then
                scope_label="local"
                status_color="${grn}"; status_label="running"
            else
                scope_label="local"
                status_color="${ylw}"; status_label="stopped"
            fi

            printf "  %s%-24s%s [%s%s%s] %s%s%s\n" \
                "${cyn}" "$dir_name" "${rst}" \
                "${status_color}" "$status_label" "${rst}" \
                "${blu}" "$scope_label" "${rst}"
        done
    else
        _log WARN "No valid stacks found in $csm_dir"
    fi

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        echo ""
        _log WARN "Directories missing a compose file (empty or broken):"
        for dir_name in "${empty_dirs[@]}"; do
            printf "  %s%-24s%s [ %s%s%s ]\n" \
                "${wht}" "$dir_name" "${rst}" \
                "${red}" "empty" "${rst}"
        done
    fi
}

stack_ps() {
    _log STEP "stack_ps: listing all containers"
    _check_cmd
    local swarm_active=false
    _detect_swarm && swarm_active=true
    _log STEP "stack_ps: swarm_active=$swarm_active"

    # List all containers with improved formatting
    {
        printf "%s%-20s %-30s %-20s %-20s%s\n" "${bld}" "CONTAINER ID" "NAME" "STATUS" "PORTS" "${rst}"
        $csm_cmd ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | \
        sort -k2,2 | \
        sed -E "
            s/^([^ \t]+)\t([^ \t]+)\t([^ \t]+)\t(.+)/\1\t${cyn}\2${rst}\t\3\t\4/
            s/0\.0\.0\.0://g; s/\[::\]://g; s/->[0-9]+\/[a-z]+//g; s/, //g
            s/unhealthy/${red}unhealthy${rst}/g
            s/healthy/${grn}healthy${rst}/g
            s/([0-9]+\/[a-z]+)/${blu}\1${rst}/g
        "
    } | column -ts $'\t'
    # # TODO: Needs testing; while loops are slower than `sed` but more portable.
    # while IFS=$'\t' read -r id name status ports; do
    #     # Clean ports (Bash string replacement)
    #     ports="${ports//0.0.0.0:/}"
    #     ports="${ports//[::]:/}"
    #     ports="${ports//->[0-9]+\/[a-z]+ /}"

    #     # Color status
    #     if [[ "$status" == *"unhealthy"* ]]; then status="${red}unhealthy${rst}"; fi
    #     if [[ "$status" == *"healthy"* ]]; then status="${grn}healthy${rst}"; fi

    #     printf "%s\t%s%s%s\t%s\t%s\n" "$id" "$cyn" "$name" "$rst" "$status" "$ports"
    # done < <($csm_cmd ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | sort -k2,2)

    # Swarm specific service listings
    if $swarm_active; then
        local services
        services="$(docker stack ls 2>/dev/null | awk 'NR>1 {print $1}')"
        if [[ -n "$services" ]]; then
            echo ""
            _log INFO "Swarm services:"
            while IFS= read -r svc; do
                printf "  %s%s%s\n" "${cyn}" "$svc" "${rst}"
                docker service ps "$svc" --no-trunc --format "table {{.Name}}\t{{.CurrentState}}\t{{.Node}}\t{{.DesiredState}}" 2>/dev/null | \
                    tail -n +2 | sed 's/^/    /'
            done <<< "$services"
        fi
    fi
}

stack_status() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_status: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_status: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_status: running docker service ps $stack_name"
            docker service ps "$stack_name" ;;
        local)
            _log STEP "stack_status: running $csm_cmd compose -f $f ps"
            $csm_cmd compose -f "$f" ps ;;
    esac
}

stack_validate() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_validate: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_validate: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_validate: swarm mode, skipping config validation"
            _log INFO "Swarm does not support config validation without deployment."
            ;;
        local)
            _log STEP "stack_validate: running $csm_cmd compose -f $f config -q"
            if $csm_cmd compose -f "$f" config -q 2>&1; then
                _log PASS "Config valid: $f"
            else
                _log EXIT "Config invalid: $f"
            fi
            ;;
    esac
}

stack_inspect() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    _log STEP "stack_inspect: name=$stack_name, compose=$f"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_inspect: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_inspect: running docker stack ps $stack_name"
            docker stack ps "$stack_name"
            ;;
        local)
            _log STEP "stack_inspect: running $csm_cmd compose -f $f config"
            $csm_cmd compose -f "$f" config
            ;;
    esac
}

stack_logs() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local f; f="$(_require_compose_file "$stack_name")"
    local lines="${2:-50}"
    _log STEP "stack_logs: name=$stack_name, lines=$lines"
    _check_cmd
    _detect_scope "$stack_name"
    _log STEP "stack_logs: scope=$scope"
    case "$scope" in
        swarm)
            _log STEP "stack_logs: running docker service logs --tail $lines -f $stack_name"
            docker service logs --tail "$lines" -f "$stack_name"
            ;;
        local)
            _log STEP "stack_logs: running $csm_cmd compose -f $f logs -f --tail=$lines"
            $csm_cmd compose -f "$f" logs -f --tail="$lines"
            ;;
    esac
}

stack_cd() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "stack_cd: name=$stack_name, dir=$stack_dir"
    _check_cmd
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found at $stack_dir"; fi
    echo "$stack_dir"
}

_run_net_list() {
    _log STEP "_run_net_list: listing networks"
    printf "%s%-30s %-10s %-10s %s%s\n" "${bld}" "NAME" "DRIVER" "SCOPE" "ID" "${rst}"
    $csm_cmd network ls --format "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}" | sort | column -ts $'\t'
}

net_info() {
    local action="${1:-list}"
    local target="${2:-${csm_net_name}}"

    _log STEP "net_info: action=$action"
    _check_cmd

    case "$action" in
        h|host)
            _log STEP "net_info: detecting host IP"
            printf "Host IP : %s\n" \
                "$(curl -fsSL ifconfig.me 2>/dev/null || echo 'unavailable')"
            ;;
        i|inspect)
            _log STEP "net_info: inspecting network $target"
            $csm_cmd network inspect "$target"
            ;;
        l|ls|list)
            # Explicit list call
            _run_net_list
            ;;
        *)
            # This handles both the default "list" and "mis-typed" entries
            _run_net_list

            # If the action wasn't empty/list, it was a typo
            if [[ "$action" != "list" ]]; then
                _log WARN "Unknown net action: $action"
                _log INFO "Available: h|host, i|inspect [name], l|ls|list"
                return 1
            fi
            ;;
    esac
}

# =============================================================================
# CONFIG MANAGEMENT (public)
# =============================================================================

manage_config() {
    local action="${1:-show}"
    shift || true
    _log STEP "manage_config: action=$action"
    case "$action" in
        show)
            _log INFO "Active configuration:"
            printf "  %-28s = %s\n" \
                "csm_cmd:"      "${csm_cmd:-<not detected>}" \
                "csm_net_name:"  "$csm_net_name" \
                "csm_gid/group:" "$csm_gid/$csm_group" \
                "csm_uid/owner:" "$csm_uid/$csm_owner" \
                "csm_dir:"       "$csm_dir"   \
                "csm_backups:"   "$csm_backups"  \
                "csm_configs:"   "$csm_configs"  \
                "csm_modules:"   "$csm_modules"  \
                "csm_secrets:"   "$csm_secrets"  \
            ;;
        edit)
            local ucfg="${csm_configs}/user.conf"
            _log STEP "manage_config: editing $ucfg"
            if [[ ! -f "$ucfg" ]]; then mkdir -p "$csm_configs"; touch "$ucfg"; fi
            "${EDITOR:-vi}" "$ucfg"
            ;;
        reload)
            _log STEP "manage_config: reloading config..."
            _load_config
            _log PASS "Configuration reloaded."
            ;;
        *)
            _log FAIL "Unknown config action: $action  (use: show | edit | reload)"
            return 1
            ;;
    esac
}

# =============================================================================
# TEMPLATE MANAGEMENT (public, stub)
# =============================================================================

manage_module() {
    _log WARN "The 'modules' command is not yet implemented."
    _log WARN "When released, it will list available modules from"
    _log WARN "https://codeberg.com/techtinker/homelab and allow you to"
    _log WARN "download and run a module to install an app stack."

    ##TODO: possible start to module management function code
    # local action="${1:-list}"
    # shift || true
    # case "$action" in
    #     list)
    #         local tdir="${csm_modules}"
    #         if [[ ! -d "$tdir" ]]; then log WARN "No modules directory: $tdir"; return 0; fi
    #         log INFO "Available modules:"
    #         find "$tdir" -mindepth 1 -maxdepth 1 -type d | sort | \
    #             while IFS= read -r t; do
    #                 printf "  %s%s%s\n" "${cyn}" "$(basename "$t")" "${rst}"
    #             done
    #         ;;
    #     add|remove|update)
    #         log WARN "module $action: not yet implemented."
    #         ;;
    #     *)
    #         log FAIL "Unknown module action: $action  (use: list | add | remove | update)"
    #         return 1
    #         ;;
    # esac
}

# =============================================================================
# SHELL ALIAS GENERATOR
# =============================================================================

_print_aliases() {
    _log STEP "_print_aliases: "
    cat <<ALIAS
# Container Stack Manager — shell helpers
# Source this in your shell rc:  eval "\$(csm --aliases)"

# Check host and container IPs
hostip() { echo "Host IP: \$(curl -fsSL ifconfig.me 2>/dev/null || wget -qO- ifconfig.me)"; }
lancheck() { echo "Container IP: \$(${csm_cmd} container exec -it "\${*}" curl -fsSL ipinfo.io 2>/dev/null || wget -qO- ipinfo.io)"; }
vpncheck() { echo "Container IP: \$(${csm_cmd} container exec -it "\${*}" curl -fsSL ipinfo.io/ip 2>/dev/null || wget -qO- ipinfo.io/ip)" && \\
            echo "     Host IP: \$(curl -fsSL ifconfig.me 2>/dev/null || wget -qO- ifconfig.me)"; }

# cd into stacks directory or a specific stack
alias cds='cd ${csm_dir}'
ALIAS
}

# =============================================================================
# HELP (public)
# =============================================================================

show_help() {
    cat <<EOF
${bld}Container Stack Manager (CSM) v${csm_version}${rst}

${bld}Usage:${rst} csm <command> [<stack-name>] [options]

${bld}Stack Lifecycle:${rst}
    c  | create   <n>           Create a new stack directory + compose scaffold
    n  | new      <n>           Create a new stack directory + compose scaffold
    e  | edit     <n>           Open compose.yml in \$EDITOR
    r  | rename   <old> <new>   Rename a stack directory
    rm | remove   <n>           Stop and remove containers in a stack (prompts)
    dt | delete   <n>           Stop and PERMANENTLY delete stack + all data (prompts)
    bu | backup   <n>           Tar-gz the stack directory to .backup/
    rc | recreate <n>           Delete and recreate a stack from scratch (prompts)
    xx | purge    [n...]        Purge stacks — WARNING THIS IS FINAL

${bld}Swarm Stack Operations:${rst}
    u  | up       <n>           Deploy a stack (up -d --remove-orphans)
    d  | down     <n>           Stop and remove containers (down)
    b  | bounce   <n>           Bring stack down then back up (full recreate)
    st | start    <n>           Start stopped containers
    sp | stop     <n>           Stop containers without removing
    rs | restart  <n>           Restart containers
    ud | update   <n>           Pull latest images then redeploy

${bld}Information:${rst}
    l  | list                   List all stacks with running state
    s  | status   <n>           Show container/service status for a stack
    v  | validate <n>           Validate compose.yml syntax
    i  | inspect  <n>           Inspect stack configuration
    g  | logs     <n> [lines]   Follow logs (default: last 50 lines)
    cd            <n>           Print the stack directory path
    ps                          List all containers (formatted)
    net           <action>      Network info: h|host | i|inspect [name] | l|list
    t  | module               Template management (not yet implemented)

${bld}Config:${rst}
    cfg | config (show | edit | reload)  Displays, Edits, or Reloads CSM configs.

${bld}Secrets:${rst}
    secret     <name> <value>   Create a Docker secret (swarm required)
    secret-rm  <name>           Remove a Docker secret
    secret-ls                  List all Docker secrets

${bld}Options:${rst}
    -h | --help            Show this help
    -V | --version         Show version
    --aliases              Print shell aliases to eval in your shell rc

${bld}Container Stack Manager (csm.sh) version:${rst} ${ylw}${csm_version}${rst}
EOF
}

# =============================================================================
# COMMAND DISPATCHER
# =============================================================================

main() {
    local cmd="${1:-}"
    _color_setup
    _log STEP "main() called with cmd='$cmd'"
    if [[ -z "$cmd" ]]; then show_help; exit 0; fi
    shift || true

    _log STEP "Setting up colors..."
    _log STEP "Loading config files..."
    _load_config

    case "$cmd" in
        -a | --aliases)         _print_aliases; exit 0 ;;
        -h | --help | h | help) show_help; exit 0 ;;
        -v | --version)         echo "CSM v${csm_version}"; exit 0 ;;
    esac

    _log STEP "Validating config..."
    _validate_config || true
    _log STEP "Detecting container runtime..."
    _detect_command
    _log STEP "Using runtime: $csm_cmd"

    _log STEP "Dispatching command: '$cmd'"
    case "$cmd" in
        c|create|n|new) stack_create    "$@" ;;
        e|edit)         stack_edit      "$@" ;;
        r|rename)       stack_rename    "$@" ;;
        bu|backup)      stack_backup    "$@" ;;
        dt|delete)      stack_delete    "$@" ;;
        rm|remove)      stack_remove    "$@" ;;
        xx|purge)       stack_purge     "$@" ;;
        u|up)           stack_up        "$@" ;;
        d|dn|down)      stack_down      "$@" ;;
        b|bounce)       stack_bounce    "$@" ;;
        st|start)       stack_start     "$@" ;;
        sp|stop)        stack_stop      "$@" ;;
        rs|restart)     stack_restart   "$@" ;;
        rc|recreate)    stack_recreate  "$@" ;;
        ud|update)      stack_update    "$@" ;;
        i|inspect)      stack_inspect   "$@" ;;
        l|ls|list)      stack_list           ;;
        s|status)       stack_status    "$@" ;;
        v|validate)     stack_validate  "$@" ;;
        g|logs)         stack_logs      "$@" ;;
        cd)             stack_cd        "$@" ;;
        ps)             stack_ps             ;;
        net)            net_info        "$@" ;;
        cfg|config)     manage_config   "$@" ;;
        m|module)       manage_module   "$@" ;;
        secret)         secret_create   "$@" ;;
        secret-rm)      secret_remove   "$@" ;;
        secret-ls)      secret_list          ;;
        *) _log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
