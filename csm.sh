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

csm_debug="0" # set to "1" to display debug step messages
csm_cmd=""    # set by _detect_runtime
scope=""      # set by _detect_scope

# Permission modes (symbolic form — compatible with GNU and BSD install)
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

_detect_os() {
    os_type=$(uname -s)
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

_detect_runtime() {
    if podman compose version >/dev/null 2>&1; then
        csm_cmd="podman"
        _log STEP "_detect_runtime: using podman"
    elif docker compose version >/dev/null 2>&1; then
        csm_cmd="docker"
        _log STEP "_detect_runtime: using docker"
    elif command -v docker-compose >/dev/null 2>&1; then
        _log EXIT "'docker-compose' v1 is unsupported. Upgrade to 'docker compose' (v2)."
    else
        _log EXIT "No supported container runtime found. Install Docker or Podman."
    fi
}

_detect_swarm() {
    if [[ "$csm_cmd" == "podman" ]]; then
        _log STEP "_detect_swarm: podman detected, skipping"
        return 1
    fi
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
    _log STEP "_detect_swarm: swarm state=$swarm_state"
    if [[ "$swarm_state" == "active" ]]; then return 0; fi
    return 1 # Explicit return
}

_check_prereqs() {
    _log STEP "_check_prereqs: checking container runtime, permissions, and group..."

    # Detect container runtime first
    if [[ -z "${csm_cmd:-}" ]]; then
        _detect_runtime
    fi

    # Set global swarm_active and swarm_stacks
    if _detect_swarm; then
        swarm_active=true
        swarm_stacks="$(_get_swarm_stacks)"
    else
        swarm_active=false
        swarm_stacks=""
    fi
    _log STEP "_check_prereqs: swarm_active=$swarm_active"

    # Check stacks directory permissions
    _ensure_perms "$csm_dir"

    # Check container group and set csm_gid
    csm_gid=$(_get_gid "$csm_group")
    if [[ -z "$csm_gid" ]]; then
        _log EXIT "Container group '$csm_group' not found or GID cannot be determined. Please run the installer to create the group."
    fi
    _log STEP "_check_prereqs: csm_group=$csm_group csm_gid=$csm_gid"

    # Set csm_uid with fallback
    csm_uid="${SUDO_UID:-$(id -u "$USER" 2>/dev/null || id -u)}"
    if [[ -z "$csm_uid" ]]; then
        _log EXIT "Unable to determine user UID. Check user setup."
    fi
    _log STEP "_check_prereqs: csm_uid=$csm_uid"

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

    # Assign directory variables with defaults
    csm_dir="${CSM_DIR:-/srv/stacks}"
    csm_backups="${CSM_BACKUPS:-${csm_dir}/.backups}"
    csm_configs="${CSM_CONFIGS:-${csm_dir}/.configs}"
    csm_secrets="${CSM_SECRETS:-${csm_dir}/.secrets}"
    csm_templates="${CSM_TEMPLATES:-${csm_dir}/.templates}"

    # Assign operation variables with defaults
    csm_gid="${CSM_GID:-$(_get_gid "${csm_cmd:-docker}")}"
    csm_uid="${CSM_UID:-$(_get_uid)}"
    csm_group="$(_get_group "$csm_gid")"
    csm_owner="$(_get_owner "$csm_uid")"
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
        _log WARN "Fix manually: sudo chmod 2770 \"$stack_dir\" && find \"$stack_dir\" -type f -exec chmod 660 {} \\;"
        return 1
    fi
    if [[ "$mode" != "2770" ]]; then
        _log STEP "_ensure_perms: incorrect perms ($mode), fixing to drwxrws---"
        find "$target" -type f -exec chmod 660 {} \;
        find "$target" -type d -exec chmod 2770 {} \;
        _log PASS "Fixed permissions on $target"
    else
        _log STEP "_ensure_perms: permissions already correct"
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
    if $swarm_active; then
        # Swarm is active, now check if stack is deployed
        if <<<"$swarm_stacks" grep -qw "$stack_name"; then
            _log STEP "_detect_scope: stack found in swarm_stacks -> swarm"
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
    elif docker network inspect ingress >/dev/null 2>&1; then
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
    local secret_file old_umask rc
    secret_file="${1:-}"
    value="${2-}"
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
    local file
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
    if [[ -z "${name// }" ]]; then _log EXIT "Secret name cannot be empty."; fi
    secret_file="${csm_secrets}/${name}.secret"

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
    docker stack ls --format '{{.Name}}' 2>/dev/null | sort
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
# _format_tabular_data() {
#     local header="$1"
#     local data_command="$2"
#     # Strip ANSI codes for column width calculation, then reapply them
#     { printf "%s%s%s\n" "${bld}" "$header" "${rst}"; eval "$data_command"; } | {
#         sed -r 's/\x1B\[[0-9;]*[mK]//g' | column -ts $'\t' | sed -r 's/\x1B\[[0-9;]*[mK]//g'
#     }
# }

stack_list() {
    _log STEP "stack_list: csm_dir=$csm_dir"
    if [[ ! -d "$csm_dir" ]]; then _log EXIT "Stacks directory not found: $csm_dir"; fi

    if $swarm_active; then
        swarm_stacks="$(_get_swarm_stacks)"
        _log STEP "stack_list: updated swarm_stacks with $(echo "$swarm_stacks" | wc -l) stacks"
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
        # Precompute running local projects to avoid per-stack subprocesses
        local running_projects=""
        running_projects="$({ $csm_cmd ps --filter status=running --format "{{.Labels}}" | { grep -o 'com\.docker\.compose\.project=[^,]*' | cut -d= -f2 | sort | uniq | tr '\n' ' '; } ; } 2>/dev/null || echo "")"

        local data=""
        for dir_name in "${valid_stacks[@]}"; do
            local stack_dir scope ports status_label
            stack_dir="${csm_dir}/${dir_name}"

            # Determine scope
            if [[ -f "${stack_dir}/.swarm" ]] || ($swarm_active && <<<"$swarm_stacks" grep -qw "$dir_name"); then
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
                # Check if compose file is valid first
                if "$csm_cmd" compose -f "${stack_dir}/compose.yml" config >/dev/null 2>&1; then
                    running_count="$({ "$csm_cmd" compose -f "${stack_dir}/compose.yml" ps --services --filter status=running | wc -l ; } 2>/dev/null || echo "0")"
                else
                    running_count="0"
                fi
                if [ "$running_count" -gt 0 ]; then
                    status_label="running"
                else
                    status_label="stopped"
                fi
            fi

            # Determine ports
            if [[ "$scope" == "swarm" ]]; then
                ports="$({ docker service ls --filter name="$dir_name" --format "{{.Ports}}" | sed 's/0\.0\.0\.0://g; s/\[::\]://g; s/\*://g' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//' ; } 2>/dev/null || echo "")"
            else
                ports="$({ "$csm_cmd" compose -f "${stack_dir}/compose.yml" ps --format "{{.Ports}}" | sed 's/0\.0\.0\.0://g; s/\[::\]://g; s/\*://g' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//' ; } 2>/dev/null || echo "")"
            fi

            # Plain fields
            local name="$dir_name"
            local status="$status_label"
            local scope_field="$scope"
            local ports_field="$ports"

            # Add to data
            data+="${scope_field}"$'\t'"${name}"$'\t'"${status}"$'\t'"${ports_field}"$'\n'
        done

        # Get all compose projects
        local all_projects=""
        all_projects="$({ $csm_cmd compose ls --all --format json | jq -r '.[]?.Name // empty' ; } 2>/dev/null || { $csm_cmd compose ls --format 'table {{.Name}}' | tail -n +2 ; } 2>/dev/null || echo "")"

        # Add unmanaged projects
        for proj in $all_projects; do
            if [[ " ${valid_stacks[*]} " != *" $proj "* ]]; then
                scope="local (unmanaged)"
                status_label="unknown"
                ports=""
                name="$proj"
                data+="${scope}"$'\t'"${name}"$'\t'"${status_label}"$'\t'"${ports}"$'\n'
            fi
        done

        # Format as table
        # _format_tabular_data "SCOPE\tSTACK\tSTATUS\tPORTS" "printf '%s' \"$data\""
        _format_tabular_data "SCOPE"$'\t'"NAME"$'\t'"STATUS"$'\t'"PORTS"  "printf '%s' \"$data\""
    else
        _log WARN "No valid stacks found in $csm_dir"
    fi

    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        echo ""
        local empty_data=""
        for dir_name in "${empty_dirs[@]}"; do
            empty_data+="missing"$'\t'"${csm_dir}/${dir_name}"$'\n'
        done
        _log WARN "Directories missing a compose file (empty or broken):"
        _format_tabular_data "STATUS\tDIRECTORY" "printf '%s' \"$empty_data\""
    fi
}

stack_ps() {
    local stack_name="${1:-}"
    _log STEP "stack_ps: listing containers ${stack_name:+ for $stack_name}"

    if [[ -n "$stack_name" ]]; then
        # Per-stack ps: route based on scope
        _detect_scope "$stack_name"
        case "$scope" in
            local)
                local file="$(_require_compose "$stack_name")"
                "$csm_cmd" compose -f "$file" ps
                ;;
            swarm)
                _detect_swarm && swarm_active=true
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
    if $swarm_active; then
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
${bld}Container Stack Manager (CSM) v${csm_version}${rst}

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
    l  | ls | list              List all stacks with running state and scope
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

${bld}Container Stack Manager (csm.sh) version:${rst} ${ylw}${csm_version}${rst}
EOF
}

# =============================================================================
# COMMAND DISPATCHER
# =============================================================================

main() {
    local cmd="${1:-}"
    _color_setup
    _detect_os
    if [[ -z "$cmd" ]]; then show_help; exit 0; fi
    case "$cmd" in
        -a | --aliases)     _print_aliases; exit 0 ;;
        -h | *help | "")    show_help; exit 0 ;;
        -v | --version)     echo "CSM v${csm_version}"; exit 0 ;;
    esac

    _setup_variables
    _check_prereqs
    shift || true

    case "$cmd" in
        c|create|n|new)     stack_create            "$@" ;;
        e|edit)             stack_edit              "$@" ;;
        r|rename)           stack_rename            "$@" ;;
        bu|backup)          stack_backup            "$@" ;;
        dt|rm|delete)       stack_delete            "$@" ;;
        ls|l|list)          stack_list                   ;;
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
