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
#   │  ├── user.conf                ← user configuration variables
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

csm_debug="${CSM_DEBUG:-0}"     # set to "1" to display debug step messages
csm_cmd=""      # set by _detect_runtime
scope=""        # set by _detect_scope
dry_run=0       # set to 1 to show what would be done without making changes
forced_mode=0   # set to 1 to force-apply permission fixes without prompting
swarm_stacks="" # populated lazily by _get_swarm_stacks / _ensure_csm_state

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_exec="770"   # executables:  rwxrwx---
readonly mode_conf="660"   # config files: rw-rw----
readonly mode_auth="600"   # secret files: rw-------

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

_detect_os() {
    os_type=$(uname -s)
    if [[ -z "$os_type" ]]; then
        _log WARN "Unable to detect OS type"
        os_type="unknown"
    fi
}

_get_mode() {
    local file
    file="${1:-}"
    case $os_type in
        Darwin|*BSD)  stat -f '%p' "$file" 2>/dev/null ;;
        Linux)        stat -c '%a' "$file" 2>/dev/null ;;
    esac
}

_get_gid() {
    local gid group_name
    group_name="${1:-}"
    gid=""

    case $os_type in
        Darwin|*BSD)
            gid=$(dscl . -read /Groups/"$group_name" PrimaryGroupID 2>/dev/null | awk '{print $2}')
            ;;
        Linux)
            gid=$(getent group "$group_name" | cut -d: -f3)
            ;;
    esac

    # Fallback: try to get from current user's groups
    if [[ -z "$gid" ]]; then
        gid=$(id -G "$USER" 2>/dev/null | tr ' ' '\n' | grep -w "$(id -gn "$USER" 2>/dev/null || echo "$group_name")" | head -1)
    fi

    echo "$gid"
}

_get_group() {
    local gid group_name
    gid="${1:-}"
    group_name=""

    case $os_type in
        Darwin|*BSD)
            group_name=$(dscl . -search /Groups PrimaryGroupID "$gid" 2>/dev/null | head -1 | cut -d: -f1)
            ;;
        Linux)
            group_name=$(getent group "$gid" | cut -d: -f1)
            ;;
    esac

    # Fallback: use id command
    if [[ -z "$group_name" ]]; then
        group_name=$(id -gn "$gid" 2>/dev/null)
    fi

    # Final fallback
    echo "${group_name:-${csm_cmd:-docker}}"
}

_get_uid() {
    local uid user_name
    user_name="${1:-$USER}"
    uid=""

    case $os_type in
        Darwin|*BSD)
            uid=$(dscl . -read /Users/"$user_name" UniqueID 2>/dev/null | awk '{print $2}')
            ;;
        Linux)
            uid=$(getent passwd "$user_name" | cut -d: -f3)
            ;;
    esac

    # Fallback: use id command (POSIX, works everywhere)
    if [[ -z "$uid" ]]; then
        uid=$(id -u "$user_name" 2>/dev/null)
    fi

    echo "$uid"
}

_get_owner() {
    local uid user_name
    uid="${1:-}"
    user_name=""

    case $os_type in
        Darwin|*BSD)
            user_name=$(dscl . -search /Users UniqueID "$uid" 2>/dev/null | head -1 | cut -d: -f1)
            ;;
        Linux)
            user_name=$(getent passwd "$uid" | cut -d: -f1)
            ;;
    esac

    # Fallback: use id command
    if [[ -z "$user_name" ]]; then
        user_name=$(id -un "$uid" 2>/dev/null)
    fi

    # Final fallback
    echo "${user_name:-$USER}"
}

# Clean Docker/Podman port strings (removes 0.0.0.0, [::], *, dedupes, trims trailing comma)
clean_ports() {
    sed 's/0\.0\.0\.0://g; s/\[::\]://g; s/\*://g' <<<"$1" |
        tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//' || true
}

_detect_runtime() {
    [[ -v csm_cmd && -n "$csm_cmd" ]] && return 0

    _log STEP "_detect_runtime: probing container runtimes..."

    if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
        declare -g csm_cmd="podman"
        _log STEP "_detect_runtime: using podman"
    elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        declare -g csm_cmd="docker"
        _log STEP "_detect_runtime: using docker"
    elif command -v docker >/dev/null 2>&1; then
        # Docker is present but compose subcommand may be separate plugin
        declare -g csm_cmd="docker"
        _log STEP "_detect_runtime: using docker (fallback)"
    elif command -v podman >/dev/null 2>&1; then
        declare -g csm_cmd="podman"
        _log STEP "_detect_runtime: using podman (fallback)"
    else
        _log EXIT "No supported container runtime (docker/podman) found."
    fi
}

_detect_swarm() {
    if [[ -v swarm_active ]]; then
        [[ "$swarm_active" == "true" ]] && return 0 || return 1
    fi

    if [[ "${csm_cmd:-}" == "podman" ]]; then
        _log STEP "_detect_swarm: podman detected, skipping"
        declare -g swarm_active=false
        declare -g swarm_state="inactive"
        return 1
    fi

    local state
    state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
    _log STEP "_detect_swarm: swarm state=$state"
    if [[ "$state" == "active" ]]; then
        declare -g swarm_active=true
        declare -g swarm_state="$state"
        return 0
    fi
    declare -g swarm_active=false
    declare -g swarm_state="$state"
    return 1
}

# Lazy cached check for the Docker Swarm ingress network (used as a heuristic for swarm mode)
_has_swarm_ingress() {
    if [[ -v swarm_ingress_checked ]]; then
        return "${swarm_has_ingress:-1}"
    fi

    local has_ingress=1
    if docker network inspect ingress >/dev/null 2>&1; then
        has_ingress=0
    fi
    declare -g swarm_has_ingress="$has_ingress"
    declare -g swarm_ingress_checked=1
    return "$has_ingress"
}

# =============================================================================
# CENTRAL STATE INITIALIZATION (authoritative lazy initialization point)
# =============================================================================
# All expensive runtime, swarm, and identity detection should go through
# this function (or the individual lazy detectors it calls). This ensures
# expensive commands (docker info, compose version, stack ls, etc.) run
# at most once per csm invocation.

# Lightweight identity initialization (gid/uid etc.)
_ensure_identity() {
    if [[ ! -v csm_gid || -z "$csm_gid" ]]; then
        declare -g csm_gid="${CSM_GID:-$(_get_gid "${csm_cmd:-docker}")}"
    fi
    if [[ ! -v csm_uid || -z "$csm_uid" ]]; then
        declare -g csm_uid="${CSM_UID:-$(_get_uid)}"
    fi
    if [[ ! -v csm_group || -z "$csm_group" ]]; then
        declare -g csm_group="$(_get_group "${csm_gid:-}")"
    fi
    if [[ ! -v csm_owner || -z "$csm_owner" ]]; then
        declare -g csm_owner="$(_get_owner "${csm_uid:-}")"
    fi
}

_ensure_csm_state() {
    # Idempotent: safe to call multiple times
    if [[ "${_csm_state_initialized:-}" == "1" ]]; then
        return 0
    fi

    _detect_runtime          # sets csm_cmd (lazy inside)
    _detect_swarm            # sets swarm_active + swarm_state (lazy inside)

    if [[ "${swarm_active}" == "true" ]]; then
        swarm_stacks="$(_get_swarm_stacks)"
    else
        swarm_stacks=""
    fi

    _ensure_identity         # gid/uid/group/owner (lazy inside)

    declare -g _csm_state_initialized=1
}

_check_prereqs() {
    _log STEP "_check_prereqs: checking container runtime, permissions, and group..."

    _ensure_csm_state

    _log STEP "_check_prereqs: swarm_active=$swarm_active"

    # Validate/ensure identity (in case user.conf overrode values)
    if [[ -z "${csm_gid:-}" ]]; then
        csm_gid="$(_get_gid "${csm_group:-docker}")"
    fi
    if [[ -z "$csm_gid" ]]; then
        _log EXIT "Container group '$csm_group' not found or GID cannot be determined."
    fi

    if [[ -z "${csm_uid:-}" ]]; then
        csm_uid="${SUDO_UID:-$(id -u "$USER" 2>/dev/null || id -u)}"
    fi
    if [[ -z "$csm_uid" ]]; then
        _log EXIT "Unable to determine user UID."
    fi

    _log STEP "_check_prereqs: csm_group=$csm_group csm_gid=$csm_gid csm_uid=$csm_uid"

    # Check stacks directory permissions (now that uid/gid are known)
    _ensure_perms "$csm_dir"

    # Check backups directory existence
    if [[ ! -d "$csm_backups" ]]; then
        _log WARN "Backups directory not found: $csm_backups (run csm-install.sh to repair)"
    fi
}

_confirm_yes() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    if [[ -z "${reply}" || "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1 so the script doesn't crash
}

_confirm_no() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${red}${bld} ${prompt} [y/N]: ${rst}" reply
    if [[ "${reply,,}" == "y" ]]; then return 0; fi
    return 1 # Explicitly return 1
}

# =============================================================================
# CONFIGURATION
# =============================================================================

_setup_variables() {
    local config_files=(
        "${script_dir}/user.conf"
        "${HOME}/.config/csm/user.conf"
    )

    for config in "${config_files[@]}"; do
        if [[ -f "$config" ]]; then
            source "$config"
            _log STEP "_setup_variables: sourced $config"
        fi
    done

    # Directory variables (cheap)
    csm_dir="${CSM_DIR:-/srv/stacks}"
    csm_backups="${CSM_BACKUPS:-${csm_dir}/.backups}"
    csm_configs="${CSM_CONFIGS:-${csm_dir}/.configs}"
    csm_secrets="${CSM_SECRETS:-${csm_dir}/.secrets}"
    csm_templates="${CSM_TEMPLATES:-${csm_dir}/.templates}"

    # Use central lazy identity initialization
    _ensure_identity

    csm_network="${CSM_NET_NAME:-csm_network}"
    csm_version="${CSM_VERSION:-unknown}"
}

_ensure_perms() {
    local target="${1:-}"
    _log STEP "_ensure_perms: ensuring correct permissions on $target"

    if [[ ! -d "$target" ]]; then
        _log WARN "Directory not found: $target"
        return 1
    fi

    local mode
    mode="$(_get_mode "$target")"
    if [[ -z "$mode" ]]; then
        _log WARN "Unable to get permissions for $target"
        _log WARN "Fix manually: chmod -R 2770 \"$target\" && find \"$target\" -type f -exec chmod 660 {} +"
        return 1
    fi

    if [[ "$mode" == "2770" ]]; then
        _log STEP "_ensure_perms: permissions already correct"
        return 0
    fi

    _log WARN "Directory $target has mode $mode (expected 2770 with setgid)."

    local should_fix=false
    if [[ "$forced_mode" == 1 ]]; then
        should_fix=true
    elif [[ "$target" == "$csm_dir" ]]; then
        if _confirm_yes "Should I run ${cyn}chmod -R${rst} for the incorrectly permissioned stacks folder?"; then
            should_fix=true
        fi
    else
        # e.g. a newly created stack directory
        if _confirm_yes "Fix permissions on $target?"; then
            should_fix=true
        fi
    fi

    if [[ "$should_fix" == true ]]; then
        _log STEP "_ensure_perms: applying permission fixes (chmod -R + batched find for speed)"
        if [[ "$dry_run" == 1 ]]; then
            _log INFO "Would correct permissions on $target"
            return 0
        fi

        # Fast correction (much quicker than per-file -exec \;)
        chmod -R 770 "$target" 2>/dev/null || true
        find "$target" -type f -exec chmod 660 {} + 2>/dev/null || true
        find "$target" -type d -exec chmod 2770 {} + 2>/dev/null || true
        find "$target" -type d -exec chmod g+s {} + 2>/dev/null || true

        _log PASS "Permissions corrected on $target"
    else
        _log WARN "Left $target with non-standard permissions."
    fi
}

_require_name() {
    if [[ ! -n "${1:-}" ]]; then _log EXIT "Stack name is required."; fi
    _log STEP "_require_name: ${1:-}"
    echo "${1:-}"
}

_get_stack_dir() {
    local stack_name dir
    stack_name="$(_require_name "${1:-}")"
    dir="${csm_dir}/${stack_name}"
    _log STEP "_get_stack_dir: $dir"
    echo "$dir"
}

_require_compose() {
    local stack_name file
    stack_name="$(_require_name "${1:-}")"
    file="${csm_dir}/${stack_name}/compose.yml"
    _log STEP "_require_compose: checking $file"
    if [[ ! -f "$file" ]]; then _log EXIT "Compose file not found: $file"; fi
    echo "$file"
}

_stack_validate() {
    local stack_name stack_dir
    stack_name="${1:-}"
    stack_dir="$(_get_stack_dir "$stack_name")"
    if [[ ! -d "$stack_dir" ]]; then
        _log EXIT "Stack '$stack_name' not found at $stack_dir"
    fi
    echo "$stack_name $stack_dir"
}

_detect_scope() {
    local stack_name stack_dir
    stack_name="${1:-}"
    stack_dir="$(_get_stack_dir "$stack_name")"
    _log STEP "_detect_scope: stack_name=$stack_name, stack_dir=$stack_dir"

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
    if [[ "${swarm_active:-false}" == "true" ]]; then
        # Swarm is active, now check if stack is deployed
        if <<<"$swarm_stacks" grep -qw "$stack_name"; then
            _log STEP "_detect_scope: stack found in swarm_stacks -> swarm"
            scope="swarm"
            return 0
        fi
        if _has_swarm_ingress; then
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

# =============================================================================
# STACK LIFECYCLE (public)
# =============================================================================

stack_create() {
    local stack_name stack_dir user_scope target_scope temp_compose temp_env
    stack_name="${1:-}"
    stack_dir="$(_get_stack_dir "$stack_name")"
    user_scope="${2:-}"
    target_scope="local"

    # Determine Target Scope
    _log STEP "stack_create: determining target scope..."
    if [[ -n "$user_scope" ]]; then
        target_scope="$user_scope"
    elif _has_swarm_ingress; then
        _log STEP "stack_create: ingress network found, defaulting to swarm"
        target_scope="swarm"
    fi

    temp_compose="$csm_configs/${target_scope}.yml"
    temp_env="$csm_configs/.${target_scope}.env"

    _log STEP "stack_create: name=$stack_name, dir=$stack_dir, scope=$target_scope"
    if [[ -d "$stack_dir" ]]; then _log EXIT "Stack '$stack_name' already exists at $stack_dir"; fi

    _log STEP "stack_create: creating directories..."
    install -o "$csm_uid" -g "$csm_gid" -m "$mode_exec" -d "$stack_dir"

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
        sed -i "s/CSM_NETWORK_PLACEHOLDER/${csm_network}/g" "$stack_dir/compose.yml"
    else
        _log WARN "Template not found: $temp_compose. Falling back to internal boilerplate."
        cat > "${stack_dir}/compose.yml" <<EOF
networks:
  ${csm_network}:
    external: true

services:
  # Add your service definitions here
  app:
    image: repo/imagename:latest
    restart: unless_stopped
    networks:
        - ${csm_network}
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
    _ensure_perms "$stack_dir"

    # Lock in the scope with a marker file
    _log STEP "stack_create: dropping .$target_scope marker file"
    touch "$stack_dir/.$target_scope"

    _log PASS "Stack '$stack_name' created at ${stack_dir} [Scope: $target_scope]"
}

stack_rename() {
    local old_name old_dir new_name new_dir
    old_name="${1:-}"
    old_dir="$(_get_stack_dir "$old_name")"
    new_name="${2:-}"
    new_dir="$(_get_stack_dir "$new_name")"

    if [[ -d "$new_dir" ]]; then
        _log EXIT "Stack '$new_name' already exists at $new_dir"
        return 1
    fi
    if [[ -d "$old_dir" ]]; then
        mv "$old_dir" "$new_dir"
        _log PASS "Stack '$old_name' renamed to '$new_name'."
    fi
}

stack_edit() {
    local stack_name stack_dir file
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"
    file="$(_require_compose "$stack_name")"
    "${EDITOR:-vi}" "$file"
}

stack_backup() {
    local stack_name stack_dir ts backup_dir backup_file
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"
    stack_name="${stack_name%/}"

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

stack_recreate() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"

    _log WARN "This will delete the current stack directory and create a clean stack with the same name."
    if ! _confirm_no "Confirm RECREATE for '$stack_name'?"; then _log INFO "Cancelled."; return 0; fi

    stack_delete "$stack_name" "force"
    stack_create "$stack_name"
}

stack_delete() {
    local stack_name stack_dir
    read -r stack_name stack_dir <<< "$(_stack_validate "${1:-}")"

    _log WARN "This will remove containers, BACKUP the stack, then PERMANENTLY DELETE '$stack_name' and ALL data."
    if ! _confirm_no "Confirm DELETE of ${cyn}$stack_dir${red} (with backup)?"; then
    _log INFO "Delete operation cancelled."; return 0; fi

    stack_ops "down" "$stack_name"
    stack_backup "$stack_name"
        rm -rf "$stack_dir"
    _log PASS "Stack '$stack_name' backed up and deleted."
}

stack_purge() {
    local target_stacks backups_deleted stack_dir
    target_stacks=("$@")
    backups_deleted=false

    # Iterate through stacksdir and add all stacks to purge list (disabled, but keep code)
    # if [[ ${#target_stacks[@]} -eq 0 ]]; then
    #     _log WARN "No stacks specified. Gathering ${mgn}ALL${ylw} stacks for purge."
    #     if ! _confirm_no "Are you sure you want to iterate through ${ylw}ALL${red} stacks?"; then
    #         _log INFO "Cancelled."
    #         return 0
    #     fi
    #     while IFS= read -r -d '' d; do
    #         target_stacks+=("$(basename "$stack_dir")")
    #     done < <(find "$csm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
    # fi

    for stack in "${target_stacks[@]}"; do
        stack_dir="$(_get_stack_dir "$stack")"
        if [[ ! -d "$stack_dir" ]]; then continue; fi

        stack_ops "down" "$stack"
        if _confirm_no "Permanently delete '${cyn}$stack${red}' folder and ${ylw}ALL${red} associated data?"; then
            rm -rf "$stack_dir"
        else
            _log INFO "Skipping $stack."
            continue
        fi

        # Nuclear option - delete backups
        if [[ -d "$csm_backups/$stack" ]] \
            && _confirm_no "Also DELETE ${ylw}ALL${red} ${cyn}$stack${red} BACKUPS in ${blu}$csm_backups/$stack${red}? This is ${mgn}IRREVERSIBLE${red}!"
        then
            rm -rf "$csm_backups/$stack"
            backups_deleted=true
            _log PASS "All ${cyn}$stack${grn} backups deleted."
        fi
        _log PASS "Stack '${cyn}$stack${grn}' purged."
    done
}

# =============================================================================
# STACK OPERATIONS (public)
# =============================================================================

stack_ops() {
    local action stack_name file
    action="$1"
    stack_name="${2:-}"
    file="$(_require_compose "$stack_name")"
    _detect_scope "$stack_name"
    stack_dir="$(_get_stack_dir "$stack_name")"

    case "$action" in
        start|up)
            case "$scope" in
                swarm)
                    if [ -f "$stack_dir/.env" ]; then
                        set -a
                        while IFS= read -r line || [ -n "$line" ]; do
                            # Ignore comments and empty lines
                            if [[ ! "$line" =~ ^# && -n "$line" ]]; then
                                eval "export $line"
                            fi
                        done < "$stacks_dir/.env"
                        set +a
                    fi
                    if docker stack deploy --detach=true -c "$file" "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' started."
                    else
                        _log EXIT "Failed to start Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    case "$action" in
                        start)
                            if "$csm_cmd" compose -f "$file" start; then
                                _log PASS "Stack '$stack_name' started."
                            else
                                _log EXIT "Failed to start Local stack '$stack_name'."
                            fi
                            ;;
                        up)
                            if "$csm_cmd" compose -f "$file" up -d --remove-orphans; then
                                _log PASS "Stack '$stack_name' is up."
                            else
                                _log EXIT "Failed to bring up Local stack '$stack_name'."
                            fi
                            ;;
                    esac
                    ;;
            esac
            ;;
        stop|down)
            case "$scope" in
                swarm)
                    if docker stack rm "$stack_name"; then
                        _log PASS "Swarm stack '$stack_name' stopped."
                    else
                        _log EXIT "Failed to stop Swarm stack '$stack_name'."
                    fi
                    ;;
                local)
                    case "$action" in
                        stop)
                            if "$csm_cmd" compose -f "$file" stop; then
                                _log PASS "Stack '$stack_name' stopped."
                            else
                                _log EXIT "Failed to stop Local stack '$stack_name'."
                            fi
                            ;;
                        down)
                            if "$csm_cmd" compose -f "$file" down; then
                                _log PASS "Stack '$stack_name' brought down."
                            else
                                _log EXIT "Failed to bring down Local stack '$stack_name'."
                            fi
                            ;;
                    esac
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

_safe_secret() {
    local secret_file value old_umask rc
    secret_file="${1:-}"
    value="${2-}"
    [[ -n "$secret_file" ]] || return 1

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

_secret_validate_file() {
    local file mode
    file="$1"

    if [[ -L "$file" ]]; then
        _log EXIT "Refusing symlinked secret file: $file"
    fi
    if [[ ! -r "$file" ]]; then
        _log EXIT "Secret file exists but is not readable: $file"
    fi

    mode="$(_get_mode "$file")"
    if [[ "${mode:-}" != "600" ]]; then
        _log WARN "Secret file permissions are ${mode:-}, expected 600."
    fi
}

secret_create() {
    local name secret_file
    name="${1:-}"
    if [[ ! "$name" =~ [^[:space:]] ]]; then _log EXIT "Secret name cannot be empty."; fi
    secret_file="${csm_secrets}/${name}.secret"

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
        _safe_secret "$secret_file" || {
            rm -f "$secret_file"
            _log EXIT "Failed to write secret file."
            }
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
    if ! read -r -s -p "Enter secret value for '$name': " value; then
        printf '\n' >&2
        _log EXIT "Failed to read secret value."
    fi
    printf '\n' >&2
    if [[ ! -n "$value" ]]; then _log EXIT "Secret value is required."; fi

    _safe_secret "$secret_file" "$value" || {
        rm -f "$secret_file"
        _log EXIT "Failed to write secret file."
        }

    docker secret create "$name" "$secret_file" \
        && _log PASS "Docker secret '$name' created from prompt input (saved to $secret_file)." \
        || { rm -f "$secret_file"; _log EXIT "Failed to create Docker secret '$name'."; }

    unset value
}

secret_remove() {
    local name secret_file
    name="${1:-}"
    secret_file="${csm_secrets}/${name}.secret"

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

stack_info() {
    local action stack_name lines file
    action="$1"
    stack_name="${2:-}"
    lines="${3:-50}"

    if [[ "$action" == "status" ]]; then stack_ps "$stack_name"; return; fi

    _require_name "$stack_name"
    case "$action" in
        logs)
            # For logs, handle service names directly for swarm
            if docker service inspect "$stack_name" >/dev/null 2>&1; then
                scope="swarm"
                file=""  # No compose file needed for direct service logs
            else
                file="$(_require_compose "$stack_name")"
                _detect_scope "$stack_name"
            fi
            ;;
        *)
            file="$(_require_compose "$stack_name")"
            _detect_scope "$stack_name"
            ;;
    esac

    # Continue with action-specific logic
    case "$action" in
        verify)
            case "$scope" in
                local) _compose_config $file ;;
                swarm)
                    if _get_swarm_stacks | grep -qw "$stack_name"; then
                        _log PASS "Stack '$stack_name' is deployed (config validated during deployment)."
                    else
                        _compose_config
                    fi
                    ;;
            esac
            ;;
        inspect)
            "$csm_cmd" compose -f "$file" config ;;
        logs)
            case "$scope" in
                local) "$csm_cmd" compose -f "$file" logs -f --tail="$lines" ;;
                swarm)
                    # Check if stack_name is a valid service name
                    if docker service inspect "$stack_name" >/dev/null 2>&1; then
                        docker service logs --tail "$lines" -f "$stack_name"
                    else
                        # Stack name not a service, show menu of services in the stack
                        local services=()
                        while IFS= read -r svc; do
                            services+=("$svc")
                        done < <(docker service ls --filter "name=$stack_name" --format "{{.Name}}" 2>/dev/null)

                        if [[ ${#services[@]} -eq 0 ]]; then
                            _log EXIT "No services found for stack '$stack_name'"
                        fi

                        _log INFO "Available services in stack '$stack_name':"
                        for i in "${!services[@]}"; do
                            printf "  %d) %s\n" "$((i+1))" "${services[$i]}"
                        done

                        local choice=""
                        read -r -p "Enter service number (or press Enter to cancel): " choice
                        if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ ]]; then
                            local index=$((choice-1))
                            if [[ $index -ge 0 && $index -lt ${#services[@]} ]]; then
                                _log INFO "Showing logs for: ${services[$index]}"
                                docker service logs --tail "$lines" -f "${services[$index]}"
                            else
                                _log WARN "Invalid selection"
                            fi
                        else
                            _log INFO "Cancelled"
                        fi
                    fi
                    ;;
            esac
            ;;
        *) _log EXIT "Unknown info operation: $action" ;;
    esac
}

_get_swarm_stacks() {
    if [[ -v swarm_stacks && -n "$swarm_stacks" ]]; then
        echo "$swarm_stacks"
        return 0
    fi

    local result
    result="$(docker stack ls --format '{{.Name}}' 2>/dev/null | sort)"
    declare -g swarm_stacks="$result"
    echo "$result"
}

_compose_config () {
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
    # Convert \t sequences in header to actual tabs for column alignment
    local header_with_tabs="${header//\\t/$'\t'}"
    { printf "%s\n" "$header_with_tabs"; eval "$data_command"; } | column -ts $'\t' | sed -E "
        1 s/^.*$/${bld}&${rst}/                     # Bold Header
        2,\$ {
            s/\b(running)\b/${grn}&${rst}/g         # Color 'running' Green
            s/\b(stopped)\b/${ylw}&${rst}/g         # Color 'stopped' Yellow
            s/\b(Exited)\b/${ylw}&${rst}/g          # Color 'Exited' Yellow
            s/^(local)(\s|$)/${blu}&/g              # Color local scope Blue
            s/^(swarm)(\s|$)/${cyn}&/g              # Color swarm scope Cyan
            s/\b(unhealthy)\b/${red}&${rst}/g       # Color 'unhealthy' Red FIRST
            s/\b(healthy)\b/${grn}&${rst}/g         # Color 'healthy' Green (only whole word)
            s/^(missing)(\s|$)/${red}&/g            # Color 'missing' Red
            s/^([^ ]+)/${blu}&/                     # Color first column Blue
            s/^([^ ]+ +)([^ ]+)/\1${mgn}\2${rst}/   # Color Name (Col 2) Magenta
        }
    "
}

stack_list() {
    local show_ports=false
    local show_unmanaged=true

    # Simple flag parsing
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p | --ports)      show_ports=true ;;
            --no-unmanaged)    show_unmanaged=false ;;
            *)                 ;;   # ignore unknown for now
        esac
        shift
    done

    _log STEP "stack_list: csm_dir=$csm_dir"
    if [[ ! -d "$csm_dir" ]]; then _log EXIT "Stacks directory not found: $csm_dir"; fi

    if [[ "$swarm_active" == true ]]; then
        # _get_swarm_stacks is now lazy/cached — this is cheap after first fetch
        swarm_stacks="$(_get_swarm_stacks)"
        _log STEP "stack_list: swarm_stacks ready ($(echo "$swarm_stacks" | wc -l) stacks)"
    fi

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
        # Precompute running local projects (status) — cheap, always useful
        local running_projects=""
        running_projects="$(
            $csm_cmd ps --filter status=running --format '{{.Labels}}' 2>/dev/null |
            grep -o 'com\.docker\.compose\.project=[^,]*' |
            cut -d= -f2 |
            sort -u |
            tr '\n' ' '
        )"

        # Expensive port precomputes — only if user wants ports
        declare -A local_project_ports=()
        declare -A swarm_service_ports=()
        if [[ "$show_ports" == true ]]; then
            # Bulk precompute ports for all running local projects
            while IFS=$'\t' read -r labels ports; do
                proj=$(grep -o 'com\.docker\.compose\.project=[^,]*' <<<"$labels" | cut -d= -f2 | head -1 || true)
                if [[ -n "$proj" ]]; then
                    local_project_ports[$proj]="$(clean_ports "$ports")"
                fi
            done < <($csm_cmd ps --filter status=running --format "{{.Labels}}\t{{.Ports}}" 2>/dev/null)

            # Bulk precompute ports for Swarm services
            if [[ "$swarm_active" == true ]]; then
                while IFS=$'\t' read -r name ports; do
                    swarm_service_ports[$name]="$(clean_ports "$ports")"
                done < <(docker service ls --format "{{.Name}}\t{{.Ports}}" 2>/dev/null)
            fi
        fi

        local data=""
        for dir_name in "${valid_stacks[@]}"; do
            local stack_dir scope ports status_label
            stack_dir="${csm_dir}/${dir_name}"

            # Determine scope
            if [[ -f "${stack_dir}/.swarm" ]] || [[ "$swarm_active" == "true" ]] && grep -qw "$dir_name" <<< "$swarm_stacks"; then
                scope="swarm"
            else
                scope="local"
            fi

            # Determine status
            if [[ "$scope" == "swarm" ]]; then
                if <<<"$swarm_stacks" grep -qw "$dir_name"; then
                    status_label="running"
                else
                    status_label="stopped"
                fi
            else
                # Check if this stack has running containers
                if [[ " $running_projects " == *" $dir_name "* ]]; then
                    status_label="running"
                else
                    status_label="stopped"
                fi
            fi

            ports=""
            if [[ "$show_ports" == true && "$status_label" == "running" ]]; then
                if [[ "$scope" == "swarm" ]]; then
                    ports="${swarm_service_ports[$dir_name]:-}"
                else
                    ports="${local_project_ports[$dir_name]:-}"
                fi
            fi

            # Plain fields
            local name="$dir_name"
            local status="$status_label"
            local scope_field="$scope"
            local ports_field="$ports"

            # Add to data
            data+="${scope_field}"$'\t'"${name}"$'\t'"${status}"$'\t'"${ports_field}"$'\n'
        done

        # Add unmanaged projects (expensive — only if requested)
        if [[ "$show_unmanaged" == true ]]; then
            local all_projects=""
            all_projects="$(
                {
                    $csm_cmd compose ls --all --format json 2>/dev/null |
                    jq -r '.[]?.Name // empty' 2>/dev/null
                } || {
                    $csm_cmd compose ls --format 'table {{.Name}}' 2>/dev/null | tail -n +2
                }
            )" | tr '\n' ' '

            for proj in $all_projects; do
                if [[ " ${valid_stacks[*]} " != *" $proj "* ]]; then
                    scope="local (unmanaged)"
                    status_label="unknown"
                    ports=""
                    name="$proj"
                    data+="${scope}"$'\t'"${name}"$'\t'"${status_label}"$'\t'"${ports}"$'\n'
                fi
            done
        fi

        # Build header based on whether ports are displayed
        local header="SCOPE"$'\t'"NAME"$'\t'"STATUS"
        if [[ "$show_ports" == true ]]; then
            header+=$'\t'"PORTS"
        fi

        # Format as table
        _format_tabular_data "$header"  "printf '%s' \"$data\""
    else
        _log WARN "No valid stacks found in $csm_dir"
    fi

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        echo ""
        local empty_data=""
        for dir_name in "${empty_dirs[@]}"; do
            empty_data+="missing"$'\t'"${csm_dir}/${dir_name}"$'\n'
        done
        _log WARN "Stack folder(s) missing a compose file:"
        _format_tabular_data "STATUS\tDIRECTORY" "printf '%s' \"$empty_data\""
    fi
}

stack_ps() {
    local stack_name="${1:-}"
    _log STEP "stack_ps: listing containers ${stack_name:+ for $stack_name}"

    _ensure_csm_state   # ensure csm_cmd, swarm_active etc. are populated

    if [[ -n "$stack_name" ]]; then
        # Per-stack ps: route based on scope
        _detect_scope "$stack_name"
        case "$scope" in
            local)
                local file="$(_require_compose "$stack_name")"
                "$csm_cmd" compose -f "$file" ps
                ;;
            swarm)
                _detect_swarm
                docker stack ps "$stack_name"
                ;;
        esac
        return
    fi

    # All containers
    _format_tabular_data "CONTAINER ID"$'\t'"NAME"$'\t'"STATUS"$'\t'"PORTS" \
        '"$csm_cmd" ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | sort -k2,2 | awk '\''BEGIN { FS="\t"; OFS="\t" } {
            gsub(/0\.0\.0\.0:/, "", $4)
            gsub(/, *\[::\]:[^ ]*/, "", $4)
            gsub(/\*:/, "", $4)
            print $1, $2, $3, $4
        }'\'

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
    if [[ "${swarm_active:-false}" == "true" ]]; then
        local services
        services="$(_get_swarm_stacks)"
        if [[ -n "$services" ]]; then
            echo ""
            echo "${bld}SWARM STACKS${rst}"
            while IFS= read -r svc; do
                printf "%s%s%s\n" "${mgn}" "$svc" "${rst}"
                docker service ps "$svc" --no-trunc --format "table {{.Name}}\t{{.CurrentState}}\t{{.Node}}\t{{.DesiredState}}" 2>/dev/null | \
                    tail -n +2 | sed 's/^/    /' || true
            done <<< "$services"
        fi
    fi
}

net_info() {
    local action="${1:-list}"
    local target="${2:-${csm_network}}"

    _log STEP "net_info: action=$action"

    case "$action" in
        h|host)
            printf "Host IP : %s\n" \
                "$(curl -fsSL ifconfig.me 2>/dev/null || echo 'unavailable')"
            ;;
        i|inspect)
            "$csm_cmd" network inspect "$target"
            ;;
        l|ls|list|"")
            _format_tabular_data "NAME"$'\t'"DRIVER"$'\t'"SCOPE"$'\t'"ID" '"$csm_cmd" network ls --format "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}" | sort'
            ;;
        *)
                _log FAIL "Unknown net action: $action"
                _log INFO "Available: h|host, i|inspect [name], l|ls|list"
                return 1
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
                "csm_network:"   "$csm_network" \
                "csm_gid/group:" "$csm_gid/$csm_group" \
                "csm_uid/owner:" "$csm_uid/$csm_owner" \
                "csm_dir:"       "$csm_dir"   \
                "csm_backups:"   "$csm_backups"  \
                "csm_configs:"   "$csm_configs"  \
                "csm_templates:" "$csm_templates"  \
                "csm_secrets:"   "$csm_secrets"  \
            ;;
        edit)
            local ucfg="${csm_configs}/user.conf"
            if [[ ! -f "$ucfg" ]]; then mkdir -p "$csm_configs"; touch "$ucfg"; fi
            "${EDITOR:-vi}" "$ucfg"
            ;;
        reload)
            _setup_variables
            _log PASS "Configuration reloaded."
            ;;
        *)
            _log FAIL "Unknown config action: $action"
            _log INFO "Usage: csm config [show|edit|reload]"
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
    _setup_variables
    _log STEP "_print_aliases: genssh, ctupdate, cds"
    cat <<ALIAS
# Container Stack Manager — shell helpers
# Source this in your shell rc:  eval "\$(csm --aliases)"

# Check host and container IPs
hostip() { echo "Host IP: \$(curl -fsSL http://ifconfig.me 2>/dev/null || wget -qO- http://ifconfig.me)"; }
lanip() { echo "Container IP: \$(${csm_cmd} container exec -it "\${1}" curl -fsSL http://ipinfo.io 2>/dev/null || wget -qO- http://ipinfo.io)"; }
vpnip() { echo "Container IP: \$(${csm_cmd} container exec -it "\${1}" curl -fsSL http://ipinfo.io/ip 2>/dev/null || wget -qO- http://ipinfo.io/ip)" && \\
            echo "     Host IP: \$(curl -fsSL http://ifconfig.me 2>/dev/null || wget -qO- http://ifconfig.me)"; }
# Create encryption key
genkey() { openssl rand -hex \${1:-32}; }
wtup() {
    [[ -z \$1 ]] || echo "Usage: ctupdate <container-name>"; return 0
    $csm_cmd run --rm --name "\$1-update" -v /var/run/$csm_cmd.sock:/var/run/$csm_cmd.sock ghcr.io/nicholas-fedor/watchtower --run-once "\$1";
}
# cd into stacks directory or a specific stack
alias cds='cd ${csm_dir}'
ALIAS
}

# =============================================================================
# HELP (public)
# =============================================================================

show_help() {
    _setup_variables
    cat <<EOF
${bld}Container Stack Manager (CSM) v-${mgn}${csm_version}${rst}

${bld}Usage:${rst} csm <command> [<stack-name>] [options]

${bld}Stack Lifecycle:${rst}
    c  | create   <stack>        Create a new stack directory + compose scaffold
    n  | new      <stack>        Alias for create
    e  | edit     <stack>        Open compose.yml in \$EDITOR
    r  | rename   <old> <new>    Rename a stack directory
    rc | recreate <stack>        Delete and recreate stack from scratch (prompts)
    bu | backup   <stack>        Archive stack to .backups/ as tar.gz
    dt | delete   <stack>        Backup, remove containers, delete stack + data
    xx | purge    [stacks...]    Purge stacks + data (optionally nuke backups)

${bld}Stack Operations:${rst}
    u  | up       <stack>        Deploy stack (up -d --remove-orphans)
    d  | down     <stack>        Stop and remove containers (down)
    b  | bounce   <stack>        Bring stack down then back up
    st | start    <stack>        Start stopped containers
    sp | stop     <stack>        Stop containers without removing
    rs | restart  <stack>        Restart containers
    ud | update   <stack>        Pull latest images then redeploy

${bld}Information:${rst}
    g  | logs     <stack> [n]   Follow logs (default: last 50 lines)
    i  | inspect  <stack>       Inspect stack configuration
    l  | ls | list [flags]     List all stacks (default: no ports, use -p/--ports to show)
    s  | status   <stack>       Show container/service status for a stack
    ps            [stack]       List all containers (formatted, colorized)
    net           [action]      Network info: host | inspect [name] | list
    t  | template [action]      Template management (not yet implemented)
    v  | verify   <stack>       Validate compose.yml syntax

${bld}Configuration:${rst}
    cfg | config (show|edit|reload)  Display, edit, or reload CSM configs

${bld}Secrets:${rst}
    secret [ls|rm] <name>       Create, list, or remove Docker secrets (swarm required)

${bld}Options:${rst}
    -a | --aliases          Print shell aliases to eval in your shell rc
    -h | --help             Show this help
    -v | --version          Show version

${bld}ls flags:${rst}
    -p | --ports              Show port mappings (requires port lookups)
    --no-unmanaged            Skip unmanaged compose project detection

${bld}Container Stack Manager (csm.sh) version:${rst} ${mgn}${csm_version}${rst}
EOF
}

# =============================================================================
# COMMAND DISPATCHER
# =============================================================================

main() {
    local cmd="${1:-}"
    _color_setup
    _detect_os
    _setup_variables
    if [[ -z "$cmd" ]]; then show_help; exit 0; fi
    case "$cmd" in
        -a | --aliases)     _print_aliases; exit 0 ;;
        -h | *help | "")    show_help; exit 0 ;;
        -v | --version)     echo "Container Stack Manager v-${mgn}${csm_version}${rst}"; exit 0 ;;
    esac

    _check_prereqs
    shift || true

    case "$cmd" in
        c|create|n|new)     stack_create            "$@" ;;
        e|edit)             stack_edit              "$@" ;;
        r|rename)           stack_rename            "$@" ;;
        bu|backup)          stack_backup            "$@" ;;
        dt|rm|delete)       stack_delete            "$@" ;;
        ls|l|list)          stack_list                   "$@" ;;
        rc|recreate)        stack_recreate          "$@" ;;
        xx|purge)           stack_purge             "$@" ;;

        b|bounce)           stack_ops "bounce"      "$@" ;;
        u|up)               stack_ops "up"          "$@" ;;
        d|dn|down)          stack_ops "down"        "$@" ;;
        rs|restart)         stack_ops "restart"     "$@" ;;
        sp|stop)            stack_ops "stop"        "$@" ;;
        st|start)           stack_ops "start"       "$@" ;;
        ud|update)          stack_ops "update"      "$@" ;;

        i|inspect)          stack_info "inspect"    "$@" ;;
        s|ps|status)        stack_info "status"     "$@" ;;
        v|verify|validate)  stack_info "verify"     "$@" ;;
        g|logs)             stack_info "logs"       "$@" ;;

        net)                net_info                "$@" ;;
        cfg|config)         manage_config           "$@" ;;
        t|template)         manage_template         "$@" ;;
        secret)             secret                  "$@" ;;
        *) _log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
