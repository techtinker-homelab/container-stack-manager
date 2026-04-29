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
#   ├── csm.ini             ← Default configuration values
#   ├── example.env         ← Example environment template
#   └── README.md           ← Project description and instructions for installation and use.
#
# Installed layout:
#   /srv/stacks/                    ← CSM root directory
#   ├── .backups/
#   │  └── <stack>/
#   │     └── <stack>-YYYYMMDD_HHMMSS.tar.gz  ← backup file for each stack
#   ├── .configs/
#   │  ├── csm.sh                   ← main CSM script containing all helper scripts
#   │  ├── csm.ini                  ← default configuration variables (from repo template)
#   │  ├── local.env                ← Podman and Docker Local variables
#   │  ├── local.yml                ← example compose.yml for "local" Docker & Podman
#   │  ├── swarm.env                ← Docker Swarm specific variables
#   │  ├── swarm.yml                ← example compose.yml for Docker Swarm only
#   │  └── user.conf                ← user overrides (optional)
#   ├── .secrets/
#   │  └── <variable_name>.secret   ← one secret file per secret variable
#   ├── .templates/
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

csm_debug="0" # set to "1" to display debug step messages
csm_cmd=""    # set by _detect_command
scope=""      # set by _detect_scope

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_dirs="770"   # directories:  rwxrwx---
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

_get_file_info() {
    local file="${1:-}"
    local info=""
    # Try GNU stat first (Linux), fallback to BSD stat
    if info=$(stat -c '%U %G %a' "$file" 2>/dev/null) || info=$(stat -f '%Su %Sg %Lp' "$file" 2>/dev/null); then
        echo "$info"
    fi
}

_get_perms() {
    local file="${1:-}"
    stat -c '%A' "$file" 2>/dev/null || stat -f '%Sp' "$file" 2>/dev/null
}

_get_gid() {
    local group="${1:-}"
    local gid=""

    # macOS/BSD with dscl
    if command -v dscl >/dev/null 2>&1; then
        gid=$(dscl . -read /Groups/"$group" PrimaryGroupID 2>/dev/null | awk '{print $2}')
    # Linux with getent
    elif command -v getent >/dev/null 2>&1; then
        gid=$(getent group "$group" | cut -d: -f3)
    fi

    # Fallback: try to get from current user's groups
    if [[ -z "$gid" ]]; then
        gid=$(id -G "$USER" 2>/dev/null | tr ' ' '\n' | grep -w "$(id -gn "$USER" 2>/dev/null || echo "$group")" | head -1)
    fi

    echo "$gid"
}

_get_group() {
    local gid="${1:-}"
    local group_name=""

    # macOS/BSD with dscl
    if command -v dscl >/dev/null 2>&1; then
        group_name=$(dscl . -search /Groups PrimaryGroupID "$gid" 2>/dev/null | head -1 | cut -d: -f1)
    # Linux with getent
    elif command -v getent >/dev/null 2>&1; then
        group_name=$(getent group "$gid" | cut -d: -f1)
    fi

    # Fallback: use id command
    if [[ -z "$group_name" ]]; then
        group_name=$(id -gn "$gid" 2>/dev/null)
    fi

    # Final fallback
    echo "${group_name:-${csm_cmd:-docker}}"
}

_get_uid() {
    local user="${1:-$USER}"
    local uid=""

    # macOS/BSD with dscl
    if command -v dscl >/dev/null 2>&1; then
        uid=$(dscl . -read /Users/"$user" UniqueID 2>/dev/null | awk '{print $2}')
    # Linux with getent
    elif command -v getent >/dev/null 2>&1; then
        uid=$(getent passwd "$user" | cut -d: -f3)
    fi

    # Fallback: use id command (POSIX, works everywhere)
    if [[ -z "$uid" ]]; then
        uid=$(id -u "$user" 2>/dev/null)
    fi

    echo "$uid"
}

_get_owner() {
    local uid="${1:-}"
    local user_name=""

    # macOS/BSD with dscl
    if command -v dscl >/dev/null 2>&1; then
        user_name=$(dscl . -search /Users UniqueID "$uid" 2>/dev/null | head -1 | cut -d: -f1)
    # Linux with getent
    elif command -v getent >/dev/null 2>&1; then
        user_name=$(getent passwd "$uid" | cut -d: -f1)
    fi

    # Fallback: use id command
    if [[ -z "$user_name" ]]; then
        user_name=$(id -un "$uid" 2>/dev/null)
    fi

    # Final fallback
    echo "${user_name:-$USER}"
}

_check_prereqs() {
    _log STEP "_check_prereqs: checking container runtime, permissions, and group..."

    # Detect container runtime first (needed before _check_cmd)
    if [[ -z "${csm_cmd:-}" ]]; then
        _detect_command
    fi

    _check_cmd
    if [[ -z "$csm_cmd" ]]; then
        _log EXIT "No container runtime found. Please install Docker or Podman first."
    fi
    _log STEP "Container runtime detected: $csm_cmd"

    # Check stacks directory permissions
    if ! _validate_permissions "$csm_dir"; then
        _log EXIT "Stacks directory '$csm_dir' has unsafe permissions. Fix with: chown $USER:$USER '$csm_dir' && chmod 770 '$csm_dir'"
    fi
    _log STEP "Stacks directory permissions are safe"

    # Check container group and set csm_gid
    csm_gid=$(_get_gid "$csm_group")
    if [[ -z "$csm_gid" ]]; then
        _log EXIT "Container group '$csm_group' not found or GID cannot be determined. Please run the installer to create the group."
    fi
    _log STEP "Container group '$csm_group' found with GID: $csm_gid"

    # Set csm_uid with fallback
    csm_uid="${SUDO_UID:-$(id -u "$USER" 2>/dev/null || id -u)}"
    if [[ -z "$csm_uid" ]]; then
        _log EXIT "Unable to determine user UID. Check user setup."
    fi
    _log STEP "_check_prereqs: csm_uid=$csm_uid"
}

_confirm_yes() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    if [[ -z "${reply}" || "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1 so the script doesn't crash
}

_confirm_no() {
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

_setup_variables() {
    local config_files=(
        "${script_dir}/csm.ini"
        "${script_dir}/user.conf"
        "${HOME}/.config/csm/user.conf"
    )

    for config in "${config_files[@]}"; do
        if [[ -f "$config" ]]; then
            source "$config"
            _log STEP "_setup_variables: sourced $config"
        fi
    done

    # Assign directory variables with defaults
    csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
    csm_backups="${CSM_BACKUPS_DIR:-${csm_dir}/.backups}"
    csm_configs="${CSM_CONFIGS_DIR:-${csm_dir}/.configs}"
    csm_secrets="${CSM_SECRETS_DIR:-${csm_dir}/.secrets}"
    csm_templates="${CSM_TEMPLATES_DIR:-${csm_dir}/.templates}"

    # Assign operation variables with defaults
    csm_gid="${CSM_STACKS_GID:-$(_get_gid "${csm_cmd:-docker}")}"
    csm_uid="${CSM_STACKS_UID:-$(_get_uid)}"
    csm_group=$(_get_group "$csm_gid")
    csm_owner=$(_get_owner "$csm_uid")
    csm_net_name="${CSM_NETWORK_NAME:-csm_network}"
    csm_version=${CSM_VERSION:-unknown}

    local reverse_proxy_list=(
        traefik
        caddy
        caddy-manager
        caddymanager
        nxpm
        nginx-proxy-manager
        npm
        haproxy
    )
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
    local mode; mode=$(_get_perms "$stack_dir")
    if [[ -z "$mode" ]]; then _log WARN "Unable to get permissions for $stack_dir"; return; fi
    _log STEP "_validate_permissions: got mode=$mode, expected 770"
    if [[ "$mode" != "770" ]]; then
        _log WARN "Incorrect permissions on $stack_dir (got $mode, expected 770)"
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

_ensure_compose_file() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local file="${csm_dir}/${stack_name}/compose.yml"
    _log STEP "_ensure_compose_file: checking $file"
    if [[ ! -f "$file" ]]; then _log EXIT "Compose file not found: $file"; fi
    echo "$file"
}

_fix_permissions() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_fix_permissions: fixing $stack_dir"
    find "$stack_dir" -type f -exec chmod 660 {} \;
    find "$stack_dir" -type d -exec chmod 770 {} \;
}

_stack_validate() {
    local stack_name stack_dir stack_name_val stack_dir_val
    stack_name="$(_require_name "${1:-}")"
    stack_dir="$(_get_stack_dir "$stack_name")"
    read -r stack_name_val stack_dir_val <<< "$("$stack_dir" "$stack_dir")"
    if [[ ! -d "$stack_dir" ]]; then
        _log EXIT "Stack '$stack_name' not found at $stack_dir"
    fi
    echo "$stack_name_val $stack_dir_val"
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

    local temp_compose="$csm_configs/${target_scope}-compose.yml"
    local temp_env="$csm_configs/.${target_scope}.env"

    _log STEP "stack_create: name=$stack_name, dir=$stack_dir, scope=$target_scope"
    if [[ -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' already exists at $stack_dir"; fi

    _log STEP "stack_create: creating directories..."
    install -o "$csm_uid" -g "$csm_gid" -m "$mode_dirs" -d "$stack_dir"
    for app_name in "${reverse_proxy_list[@]}"; do
        if [[ "${stack_name}" == "${app_name}" ]]; then
            install -o "$csm_uid" -g "$csm_gid" -m "$mode_auth" -d "$stack_dir"/certs
        fi
    done

    # Handle Compose File
    if [[ -f "$temp_compose" ]]; then
        _log STEP "stack_create: copying template $temp_compose"
        install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$temp_compose" "$stack_dir/compose.yml"

        # Inject the dynamic network name into the static template
        sed -i "s/CSM_NETWORK_PLACEHOLDER/${csm_net_name}/g" "$stack_dir/compose.yml"
    else
        _log WARN "Template not found: $temp_compose. Falling back to internal boilerplate."
        cat > "${stack_dir}/compose.yml" <<EOF
networks:
  ${csm_net_name}:
    external: true

services:
  # Add your service definitions here
  app:
    image: repo/imagename:latest
    restart: unless_stopped
    networks:
        - ${csm_net_name}
EOF
    fi

    # Handle Env File
    if [[ -f "$temp_env" ]]; then
        _log STEP "stack_create: copying env template $temp_env"
        install -o "$csm_uid" -g "$csm_gid" -m "$mode_conf" "$temp_env" "$stack_dir/.env"
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
    local old_name new_name old_dir new_dir
    old_name="$(_require_name "${1:-}")"
    new_name="$(_require_name "${2:-}")"
    old_dir="$(_get_stack_dir "$old_name")"
    new_dir="$(_get_stack_dir "$new_name")"

    _stack_exists "$old_name" "$old_dir"
    if [[ -d "$new_dir" ]]; then _log EXIT "Stack '$new_name' already exists at $new_dir"; fi

    mv "$old_dir" "$new_dir"
    _log PASS "Stack '$old_name' renamed to '$new_name'."
}

stack_edit() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"
    local f; f="$(_ensure_compose_file "$stack_name")"
    "${EDITOR:-vi}" "$f"
}

stack_backup() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"
    stack_name="${stack_name%/}"

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${csm_dir}/.backups/${stack_name}"
    backup_file="${backup_dir}/${stack_name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"
    if tar -czf "$backup_file" -C "$csm_dir" "$stack_name" 2>/dev/null; then
        _log PASS "Backup created: $backup_file"
    else
        _log FAIL "Backup failed: $backup_file"
        return 1
    fi
}

stack_remove() {
    local stack_name stack_dir force
    stack_name="$(_require_name "${1:-}")"
    stack_dir="$(_get_stack_dir "$stack_name")"
    force="${3:-}"
    _log STEP "stack_remove: name=$stack_name, dir=$stack_dir"
    _check_cmd

    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found at $stack_dir"; fi
    if [[ "$stack_dir" == "/" || "$stack_dir" == "$csm_dir" ]]; then
        _log EXIT "Safety guard: refusing to delete $stack_dir"
    fi

    if ! _confirm_no "Remove stack '$stack_name'? (all running stack containers will be removed)"; then
        _log INFO "Cancelled."
        return 0
    fi

    if [[ -f "${stack_dir}/compose.yml" ]]; then
        _detect_scope "$stack_name"
        case "$scope" in
            swarm)
                docker stack rm "$stack_name" 2>/dev/null || true ;;
            local)
                if [[ "$force" == "force" ]]; then
                    local containers
                    containers="$("$csm_cmd" compose -f "${stack_dir}/compose.yml" ps -q 2>/dev/null)" || true
                    if [[ -n "$containers" ]]; then
                        "$csm_cmd" compose -f "${stack_dir}/compose.yml" rm --stop --force
                    fi
                else
                    "$csm_cmd" compose -f "${stack_dir}/compose.yml" down 2>/dev/null || true
                fi
                ;;
        esac
    fi

    # rm -rf "$stack_dir"
    _log PASS "Stack '$stack_name' deleted."
}

stack_delete() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"

    _log WARN "This will PERMANENTLY delete '$stack_name' and ALL associated appdata."
    if ! _confirm_no "Confirm DELETE of $stack_dir?"; then _log INFO "Cancelled."; return 0; fi

    stack_remove "$stack_name" "$stack_dir" "force"
}

stack_recreate() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"

    _log WARN "This will destroy the current stack directory and create a fresh one."
    if ! _confirm_no "Confirm RECREATE for '$stack_name'?"; then _log INFO "Cancelled."; return 0; fi

    stack_remove "$stack_name" "$stack_dir" "force"
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

        if ! _confirm_no "Permanently delete stack '$stack'?"; then
            _log INFO "Skipping $stack."
            continue
        fi

        if _confirm_yes "Backup '$stack' before deletion?"; then
            stack_backup "$stack"
        fi

        if _confirm_no "Final check: DESTROY '$stack'?"; then
            stack_remove "$stack"
        else
            _log INFO "Skipped $stack at the final step."
        fi
    done

    _log PASS "Purge operations complete."
}

# =============================================================================
# STACK OPERATIONS (public)
# =============================================================================

stack_ops() {
    local action stack_name file
    action="$1"
    stack_name="$(_require_name "${2:-}")"
    file="$(_ensure_compose_file "$stack_name")"
    _detect_scope "$stack_name"

    case "$action" in
        up)
            case "$scope" in
                swarm)
                    if docker stack deploy -c "$file" "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' is up."
                    else
                        _log EXIT "Failed to bring up Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "$file" up -d --remove-orphans; then
                        _log PASS "Stack '$stack_name' is up."
                    else
                        _log EXIT "Failed to bring up Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        down)
            case "$scope" in
                swarm)
                    if docker stack rm "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' brought down."
                    else
                        _log EXIT "Failed to bring down Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "$file" down; then
                        _log PASS "Stack '$stack_name' brought down."
                    else
                        _log EXIT "Failed to bring down Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        start)
            case "$scope" in
                swarm)
                    if docker stack deploy -c "$file" "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' started."
                    else
                        _log EXIT "Failed to start Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "$file" start; then
                        _log PASS "Stack '$stack_name' started."
                    else
                        _log EXIT "Failed to start Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        stop)
            case "$scope" in
                swarm)
                    if docker stack rm "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' stopped."
                    else
                        _log EXIT "Failed to stop Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "$file" stop; then
                        _log PASS "Stack '$stack_name' stopped."
                    else
                        _log EXIT "Failed to stop Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        restart)
            case "$scope" in
                swarm)
                    if docker stack deploy -c "$file" "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' restarted."
                    else
                        _log EXIT "Failed to restart Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if "$csm_cmd" compose -f "$file" restart; then
                        _log PASS "Stack '$stack_name' restarted."
                    else
                        _log EXIT "Failed to restart Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        bounce)
            case "$scope" in
                swarm)
                    if docker stack deploy -c "$file" "$stack_name" --prune; then
                        _log PASS "Swarm stack '$stack_name' bounced (redeployed)."
                    else
                        _log EXIT "Failed to bounce Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    "$csm_cmd" compose -f "$file" down
                    if "$csm_cmd" compose -f "$file" up -d --remove-orphans; then
                        _log PASS "Stack '$stack_name' bounced."
                    else
                        _log EXIT "Failed to bounce Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        update)
            case "$scope" in
                swarm)
                    if docker stack deploy -c "$file" --resolve-image=always "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' updated."
                    else
                        _log EXIT "Failed to update Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    if ( "$csm_cmd" compose -f "$file" pull && "$csm_cmd" compose -f "$file" up -d ); then
                        _log PASS "Stack '$stack_name' updated."
                    else
                        _log EXIT "Failed to update Local stack '$stack_name'."
                    fi
                    ;;
            esac
            ;;
        *)
            _log EXIT "Unknown stack operation: $action"
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

secret() {
    local action="${1:-}"
    shift || true

    case "$action" in
        ls|list)     secret_list   "$@" ;;
        rm|remove)   secret_remove "$@" ;;
        ""|create)   secret_create "$@" ;;
        *)           _log EXIT "Unknown secret action: '$action' (use: ls, rm, or omit to create)" ;;
    esac
}

_secret_validate_file() {
    local file="$1"
    if [[ -L "$file" ]]; then
        _log EXIT "Refusing symlinked secret file: $file"
    fi
    if [[ ! -r "$file" ]]; then
        _log EXIT "Secret file exists but is not readable: $file"
    fi
    local info; info=$(_get_file_info "$file")
    local owner group perms; read -r owner group perms <<< "$info"
    if [[ "$perms" != "600" ]]; then
        _log WARN "Secret file permissions are $perms, expected 600."
    fi
}

secret_create() {
    local name="${1:-}"
    if [[ -z "${name// }" ]]; then _log EXIT "Secret name cannot be empty."; fi
    local secret_file="${csm_secrets}/${name}.secret"

    if [[ ! -n "$name" ]]; then _log EXIT "Secret name is required."; fi
    if [[ ! -d "$csm_secrets" ]]; then
        _log EXIT "The csm_secrets directory does not exist. Unable to create backup secret, exiting."
    fi

    _detect_swarm || _log EXIT "Swarm must be active to create Docker secrets."

    if docker secret inspect "$name" >/dev/null 2>&1; then
        _log EXIT "Docker secret '$name' already exists. Use 'secret-rm' first."
    fi

    if [[ -f "$secret_file" ]]; then
        _secret_validate_file "$secret_file"
        docker secret create "$name" "$secret_file" \
            && _log PASS "Docker secret '$name' created from $secret_file." \
            || _log EXIT "Failed to create Docker secret '$name' from file."
        return 0
    fi

    if [[ ! -t 0 ]]; then
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

    local value=""
    read -r -s -p "Enter secret value for '$name': " value
    printf '\n' >&2
    if [[ ! -n "$value" ]]; then _log EXIT "Secret value is required."; fi

    _safe_secret "$secret_file" "$value"

    docker secret create "$name" "$secret_file" \
        && _log PASS "Docker secret '$name' created from prompt input (saved to $secret_file)." \
        || { rm -f "$secret_file"; _log EXIT "Failed to create Docker secret '$name'."; }

    unset value
}

secret_remove() {
    local name="${1:-}"
    local secret_file="${csm_secrets}/${name}.secret"

    if [[ ! -n "$name" ]]; then _log EXIT "Secret name is required."; fi

    _detect_swarm || _log EXIT "Swarm must be active to remove Docker secrets."

    if ! _confirm_no "Remove Docker secret '$name' and backup file?"; then
        _log INFO "Cancelled."
        return 0
    fi

    if ! docker secret inspect "$name" >/dev/null 2>&1; then
        _log EXIT "Docker secret '$name' not found."
    fi

    docker secret rm "$name" \
        && _log PASS "Docker secret '$name' removed." \
        || _log EXIT "Failed to remove Docker secret '$name' (it may still be attached to a service)."

    if [[ -f "$secret_file" ]]; then
        if [[ -L "$secret_file" ]]; then _log EXIT "Refusing symlinked secret file: $secret_file"; fi
        rm -f "$secret_file" \
            && _log PASS "Backup secret file removed: $secret_file" \
            || _log WARN "Failed to remove backup secret file: $secret_file"
    fi
}

secret_list() {
    _detect_swarm || _log EXIT "Swarm must be active to list Docker secrets."
    docker secret ls --format "table {{.Name}}\t{{.CreatedAt}}\t{{.UpdatedAt}}"
}

# =============================================================================
# INFORMATION (public)
# =============================================================================

_get_swarm_stacks() {
    docker stack ls --format '{{.Name}}' 2>/dev/null | sort
}

_get_stack_status() {
    local stack_name status_label status_color
    stack_name="$1"

    _detect_scope "$stack_name"

    case "$scope" in
        swarm)
            if _get_swarm_stacks | grep -qw "$stack_name"; then
                status_color="${grn}"; status_label="deployed"
            else
                status_color="${ylw}"; status_label="stopped"
            fi
            ;;
        *)
            local stack_dir="$(_get_stack_dir "$stack_name")"
            if "$csm_cmd" compose -f "${stack_dir}/compose.yml" ps --services --filter status=running 2>/dev/null | grep -q .; then
                status_color="${grn}"; status_label="running"
            else
                status_color="${ylw}"; status_label="stopped"
            fi
            ;;
    esac
    echo "$scope" "$status_label" "$status_color"
}

_verify_compose () {
    local file="${1}"
    if "$csm_cmd" compose -f "$file" config -q 2>&1; then
        _log PASS "Config valid: $file"
    else
        _log EXIT "Config invalid: $file"
    fi
}
_format_tabular_data() {
    local header="$1"
    local data_command="$2"
    printf "%s%s%s\n" "${bld}" "$header" "${rst}"
    eval "$data_command" | column -ts $'\t'
}

stack_info() {
    local action="$1"
    local stack_name="${2:-}"
    local lines="${3:-50}"
    local file

    case "$action" in
        list)
            stack_list
            return 0
            ;;
        ps|status)
            stack_ps "$stack_name"
            return 0
            ;;
    esac

    stack_name="$(_require_name "$stack_name")"
    file="$(_ensure_compose_file "$stack_name")"
    _detect_scope "$stack_name"

    case "$action" in
        verify)
            case "$scope" in
                local)
                    _verify_compose $file
                    ;;
                swarm)
                    if _get_swarm_stacks | grep -qw "$stack_name"; then
                        _log PASS "Stack '$stack_name' is deployed (config validated during deployment)."
                    else
                        _verify_compose
                    fi
                    ;;
            esac
            ;;
        inspect) "$csm_cmd" compose -f "$file" config ;;
        logs)
            case "$scope" in
                local) "$csm_cmd" compose -f "$file" logs -f --tail="$lines" ;;
                swarm) docker service logs --tail "$lines" -f "$stack_name" ;;
            esac
            ;;
        *) _log EXIT "Unknown info operation: $action" ;;
    esac
}

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

    if [[ ${#valid_stacks[@]} -gt 0 ]]; then
        _log INFO "Active stacks in ${csm_dir}:"
        for dir_name in "${valid_stacks[@]}"; do
            local scope status_label status_color
            read -r scope status_label status_color <<< "$(_get_stack_status "$dir_name")"
            printf "  %s%-24s%s [%s%s%s] %s%s%s\n" \
                "${cyn}" "$dir_name" "${rst}" \
                "${status_color}" "$status_label" "${rst}" \
                "${blu}" "$scope" "${rst}"
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
    local stack_name="${1:-}"
    _log STEP "stack_ps: listing containers${stack_name:+ for $stack_name}"
    _check_cmd
    local swarm_active=false
    _detect_swarm && swarm_active=true
    _log STEP "stack_ps: swarm_active=$swarm_active"

    if [[ -n "$stack_name" ]]; then
        # Per-stack ps: route based on scope
        _detect_scope "$stack_name"
        local file="$(_ensure_compose_file "$stack_name")"
        case "$scope" in
            local)
                "$csm_cmd" compose -f "$file" ps
                ;;
            swarm)
                docker stack ps "$stack_name"
                ;;
        esac
        return
    fi

    # All containers
    _format_tabular_data "CONTAINER ID\tNAME\tSTATUS\tPORTS" \
        '"$csm_cmd" ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | sort -k2,2 | sed -E "
            s/^([^ \t]+)\t([^ \t]+)\t([^ \t]+)\t(.+)/\1\t${cyn}\2${rst}\t\3\t\4/
            s/0\.0\.0\.0://g; s/\[::\]://g; s/->.*\/\w+//g; s/, //g
            s/unhealthy/${red}unhealthy${rst}/g
            s/healthy/${grn}healthy${rst}/g
            s/([0-9]+\/\w+)/${blu}\1${rst}/g
        "'

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
    # done < <("$csm_cmd" ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | sort -k2,2)

    # Swarm services/tasks
    if $swarm_active; then
        local services
        services="$(_get_swarm_stacks)"
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


stack_cd() {
    local stack_name; stack_name="$(_require_name "${1:-}")"
    local stack_dir; stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "stack_cd: name=$stack_name, dir=$stack_dir"
    _check_cmd
    if [[ ! -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' not found at $stack_dir"; fi
    echo "$stack_dir"
}

_net_list() {
    _log STEP "_net_list: listing networks"
    _format_tabular_data "NAME\tDRIVER\tSCOPE\tID" '"$csm_cmd" network ls --format "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}" | sort'
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
            "$csm_cmd" network inspect "$target"
            ;;
        *)
            # also handles: l|ls|list
            _net_list

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
                "csm_templates:"   "$csm_templates"  \
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
            _setup_variables
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

manage_template() {
    _log WARN "The 'templates' command is not yet implemented."
    _log WARN "When released, it will list available templates from"
    _log WARN "https://codeberg.com/techtinker/homelab and allow you to"
    _log WARN "download and run a template to install an app stack."

    ##TODO: possible start to template management function code
    # local action="${1:-list}"
    # shift || true
    # case "$action" in
    #     list)
    #         local tdir="${csm_templates}"
    #         if [[ ! -d "$tdir" ]]; then log WARN "No templates directory: $tdir"; return 0; fi
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

# Create encryption key
keygen() { openssl rand -hex ${1:-32}; }
ctupd() {
    [[ -z $1 ]] || echo "Usage: dcupdate <container-name>"; return 0
    $csm_cmd run --rm --name "$1-update" -v /var/run/$csm_cmd.sock:/var/run/$csm_cmd.sock ghcr.io/nicholas-fedor/watchtower --run-once "$1";
}

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
    c  | create   <stack>        Create a new stack directory + compose scaffold
    n  | new      <stack>        Alias for create
    e  | edit     <stack>        Open compose.yml in \$EDITOR
    r  | rename   <old> <new>    Rename a stack directory
    rm | remove   <stack>        Stop and remove containers (prompts)
    dt | delete   <stack>        Permanently delete stack + all data (prompts)
    bu | backup   <stack>        Archive stack to .backups/ as tar.gz
    rc | recreate <stack>        Delete and recreate stack from scratch (prompts)
    xx | purge    [stack...]     Purge one or all stacks — WARNING THIS IS FINAL

${bld}Stack Operations:${rst}
    u  | up       <stack>        Deploy stack (up -d --remove-orphans)
    d  | down     <stack>        Stop and remove containers (down)
    b  | bounce   <stack>        Bring stack down then back up
    st | start    <stack>        Start stopped containers
    sp | stop     <stack>        Stop containers without removing
    rs | restart  <stack>        Restart containers
    ud | update   <stack>        Pull latest images then redeploy

${bld}Information:${rst}
    l  | list                   List all stacks with running state and scope
    s  | status   <stack>       Show container/service status for a stack
    v  | validate <stack>       Validate compose.yml syntax
    i  | inspect  <stack>       Inspect stack configuration
    g  | logs     <stack> [n]   Follow logs (default: last 50 lines)
    cd            <stack>       Print the stack directory path
    ps                          List all containers (formatted, colorized)
    net           [action]      Network info: host | inspect [name] | list
    t  | template [action]      Template management (not yet implemented)

${bld}Configuration:${rst}
    cfg | config (show|edit|reload)  Display, edit, or reload CSM configs

${bld}Secrets:${rst}
    secret [ls|rm] <name>       Create, list, or remove Docker secrets (swarm required)

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
    _setup_variables
    _check_prereqs
    if [[ -z "$cmd" ]]; then show_help; exit 0; fi
    shift || true

    case "$cmd" in
        -a | --aliases)         _print_aliases; exit 0 ;;
        -h | --help | h | help) show_help; exit 0 ;;
        -v | --version)         echo "CSM v${csm_version}"; exit 0 ;;
    esac

    _validate_config || true
    case "$cmd" in
        c|create|n|new) stack_create            "$@" ;;
        e|edit)         stack_edit              "$@" ;;
        r|rename)       stack_rename            "$@" ;;
        bu|backup)      stack_backup            "$@" ;;
        dt|delete)      stack_delete            "$@" ;;
        rc|recreate)    stack_recreate          "$@" ;;
        rm|remove)      stack_remove            "$@" ;;
        xx|purge)       stack_purge             "$@" ;;
        u|up)           stack_ops "up"          "$@" ;;
        d|dn|down)      stack_ops "down"        "$@" ;;
        b|bounce)       stack_ops "bounce"      "$@" ;;
        st|start)       stack_ops "start"       "$@" ;;
        sp|stop)        stack_ops "stop"        "$@" ;;
        rs|restart)     stack_ops "restart"     "$@" ;;
        ud|update)      stack_ops "update"      "$@" ;;
        i|inspect)      stack_info "inspect"    "$@" ;;
        l|ls|list)      stack_info "list"            ;;
        s|status)       stack_info "status"     "$@" ;;
        v|verify)       stack_info "verify"     "$@" ;;
        g|logs)         stack_info "logs"       "$@" ;;
        cd)             stack_cd                "$@" ;;
        ps)             stack_ps                     ;;
        net)            net_info                "$@" ;;
        cfg|config)     manage_config           "$@" ;;
        t|template)     manage_template         "$@" ;;
        secret)         secret                  "$@" ;;
        *) _log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
