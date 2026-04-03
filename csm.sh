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

csm_cmd=""    # set by detect_compose_command

# Permission modes (symbolic form — compatible with GNU and BSD install)
readonly mode_dirs="775"    # directories: rwxrwxr-x
readonly mode_exec="770"   # executables: rwxrwx---
readonly mode_conf="660"   # config files: rw-rw----
readonly mode_auth="600"   # secrets:      rw-------

# =============================================================================
# 1. HELPER FUNCTIONS
# =============================================================================

tput_safe() { command -v tput >/dev/null 2>&1 && tput "$@" 2>/dev/null || true; }

color_setup() {
    if [[ -t 1 ]]; then
        red=$(tput_safe setaf 1)
        grn=$(tput_safe setaf 2)
        ylw=$(tput_safe setaf 3)
        blu=$(tput_safe setaf 4)
        prp=$(tput_safe setaf 5)
        cyn=$(tput_safe setaf 6)
        wht=$(tput_safe setaf 7)
        blk=$(tput_safe setaf 0)
        bld=$(tput_safe bold)
        uln=$(tput_safe smul)
        rst=$(tput_safe sgr0)
    else
        red="" grn="" ylw="" blu="" prp="" cyn=""
        wht="" blk="" bld="" uln="" rst=""
    fi
}
color_setup

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

confirm_no() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld}  ${prompt} [y/N]: ${rst}" reply
    [[ "${reply,,}" == "y" ]]
}

confirm_yes() {
    local prompt="${1:-Are you sure?}"
    read -r -p "${ylw}${bld} ${prompt} [Y/n]: ${rst}" reply
    [[ -z "${reply}" || "${reply,,}" == "y" ]]
}

# =============================================================================
# 2. CONFIGURATION
# =============================================================================

detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        csm_cmd="docker"
    elif podman compose version >/dev/null 2>&1; then
        csm_cmd="podman"
    elif command -v docker-compose >/dev/null 2>&1; then
        die "'docker-compose' v1 is unsupported. Upgrade to 'docker compose' (v2)."
    else
        die "No supported container runtime found. Install Docker or Podman."
    fi
}

detect_scope() {
    local stack_name="$1"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    local f; f="${stack_dir}/compose.yml"

    # Podman has no swarm — always local
    [[ "$csm_cmd" == "podman" ]] && { scope="local"; return; }

    # Explicit marker files still override auto-detect
    [[ -f "${stack_dir}/.swarm" ]] && { scope="swarm"; return; }
    [[ -f "${stack_dir}/.local" ]] && { scope="local"; return; }

    # Is Swarm active on this node?
    local swarm_state
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
    [[ "$swarm_state" != "active" ]] && { scope="local"; return; }

    # Swarm is active — is this stack already deployed to it?
    if docker stack ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qw "$stack_name"; then
        scope="swarm"
        return
    fi

    # Not deployed yet — check compose file for swarm-specific syntax
    if [[ -f "$f" ]]; then
        # Swarm indicators: deploy.mode (global/replicated), endpoint_mode, or placement constraints
        if grep -qE '^\s+mode:\s+(global|replicated)' "$f" 2>/dev/null \
            || grep -qE '^\s+endpoint_mode:' "$f" 2>/dev/null \
            || grep -qE '^\s+placement:' "$f" 2>/dev/null; then
            scope="swarm"
            return
        fi
    fi

    # Default to local
    scope="local"
}

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
    csm_dir="${CSM_ROOT_DIR:-/srv/stacks}"
    csm_backup="${CSM_BACKUP_DIR:-${csm_dir}/.backup}"
    csm_common="${CSM_COMMON_DIR:-${csm_dir}/.common}"
    csm_configs="${CSM_CONFIGS_DIR:-${csm_common}/configs}"
    csm_secrets="${CSM_SECRETS_DIR:-${csm_common}/secrets}"
    csm_template="${CSM_TEMPLATE_DIR:-${csm_common}/templates}"
    csm_net_name="${CSM_NETWORK_NAME:-csm_network}"
}

validate_config() {
    local errors=0
    for dir in "$csm_dir" "$csm_backup" "$csm_common"; do
        if [[ ! -d "$dir" ]]; then
            log WARN "Directory not found: $dir  (run csm-install.sh to repair)"
            (( errors++ )) || true
        fi
    done
    return $errors
}

validate_permissions() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || return 0
    local perm
    perm=$(stat -c '%a' "$stack_dir" 2>/dev/null || stat -f '%Lp' "$stack_dir")
    if [[ "$perm" != "770" ]]; then
        log WARN "Incorrect permissions on $stack_dir (got $perm, expected 770)"
        log WARN "Fix manually: chmod 770 \"$stack_dir\" && find \"$stack_dir\" -type f -exec chmod 660 {} \\;"
    fi
}

# =============================================================================
# 3. INTERNAL HELPERS
# =============================================================================

container_exists() {
    $csm_cmd inspect "$1" >/dev/null 2>&1
}

require_name() {
    [[ -n "${1:-}" ]] || die "Stack name is required."
    echo "$1"
}

get_stack_dir() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    echo "${csm_dir}/${stack_name}"
}

require_compose_file() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f="${csm_dir}/${stack_name}/compose.yml"
    [[ -f "$f" ]] || die "Compose file not found: $f"
    echo "$f"
}

fix_permissions() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    find "$stack_dir" -type f -exec chmod 660 {} \;
    find "$stack_dir" -type d -exec chmod 770 {} \;
}

del_safe() {
    local stack_name="$1"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"

    [[ -d "$stack_dir" ]] || return 0  # Already gone
    [[ "$stack_dir" == "/" || "$stack_dir" == "$csm_dir" ]] && \
        die "Safety guard: refusing to delete $stack_dir"

    # Detect scope and stop/remove containers accordingly
    if [[ -f "${stack_dir}/compose.yml" ]]; then
        detect_scope "$stack_name"
        case "$scope" in
            swarm)
                docker stack rm "$stack_name" 2>/dev/null || true
                ;;
            local)
                stack_stop "$stack_name" >/dev/null 2>&1 || true
                ;;
        esac
    fi

    rm -rf "$stack_dir"
    log PASS "Stack '$stack_name' deleted."
}

# =============================================================================
# 4. STACK LIFECYCLE
# =============================================================================

stack_create() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    local env_file="${csm_common}/.docker.env"

    [[ -d "$stack_dir" ]] && die "Stack '$stack_name' already exists at $stack_dir"

    mkdir -p "${stack_dir}/appdata"
    install -o "$csm_uid" -g "$csm_gid" -m "$mode_dirs" -d "$stack_dir"
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

    if [[ -f "$env_file" ]]; then
        ln -s "$env_file" "${stack_dir}/.env"
    else
        : > "${stack_dir}/.env"
    fi

    fix_permissions "$stack_name"

    log PASS "Stack '$stack_name' created at ${stack_dir}"
}

stack_modify() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    "${EDITOR:-vi}" "$f"
}

stack_backup() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found."

    local ts backup_dir backup_file
    ts="$(date +%Y%m%d_%H%M%S)"
    backup_dir="${csm_backup}/${stack_name}"
    backup_file="${backup_dir}/${stack_name}_${ts}.tar.gz"

    mkdir -p "$backup_dir"
    log INFO "Creating backup: $backup_file"
    tar -czf "$backup_file" -C "$csm_dir" "$stack_name"
    log PASS "Backup complete: $backup_file"
}

stack_remove() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found at $stack_dir"

    confirm_no "Remove stack '$stack_name'? (all running stack containers will be removed)" \
        || { log INFO "Cancelled."; return 0; }

    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            docker stack rm "$stack_name" \
                && log PASS "Swarm stack '$stack_name' removed." \
                || die "Failed to remove Swarm stack '$stack_name'."
            ;;
        local)
            local f; f="$(require_compose_file "$stack_name")"
            local containers
            containers=$($csm_cmd compose -f "$f" ps -q 2>/dev/null) || true
            if [[ -n "$containers" ]]; then
                $csm_cmd compose -f "$f" rm --stop --force
            fi
            log PASS "Stack '$stack_name' containers removed."
            ;;
    esac
}

stack_delete() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found at $stack_dir"

    log WARN "This will PERMANENTLY delete '$stack_name' and ALL associated appdata."
    confirm_no "Confirm DELETE of $stack_dir?" || { log INFO "Cancelled."; return 0; }

    del_safe "$stack_name"
}

stack_recreate() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local stack_dir; stack_dir="$(get_stack_dir "$stack_name")"
    [[ -d "$stack_dir" ]] || die "Stack '$stack_name' not found."

    log WARN "This will destroy the current stack directory and create a fresh one."
    confirm_no "Confirm RECREATE for '$stack_name'?" || { log INFO "Cancelled."; return 0; }

    del_safe "$stack_name"
    stack_create "$stack_name"
}

stack_purge() {
    local target_stacks=("$@")

    # If no stacks specified, gather ALL non-hidden directories
    if [[ ${#target_stacks[@]} -eq 0 ]]; then
        log WARN "No stacks specified. Gathering ALL stacks for purge."
        confirm_no "Are you sure you want to iterate through ALL stacks?" || { log INFO "Cancelled."; return 0; }
        while IFS= read -r -d '' d; do
            target_stacks+=("$(basename "$d")")
        done < <(find "$csm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
    fi

    for stack in "${target_stacks[@]}"; do
        local d; d="$(get_stack_dir "$stack")"
        [[ -d "$d" ]] || continue

        log STEP "Evaluating: $stack"

        # 1st Confirmation (Default N)
        if ! confirm_no "Permanently delete stack '$stack'?"; then
            log INFO "Skipping $stack."
            continue
        fi

        # Backup Offer (Default Y)
        if confirm_yes "Backup '$stack' before deletion?"; then
            stack_backup "$stack"
        fi

        # 2nd Confirmation (Default N)
        if confirm_no "Final check: DESTROY '$stack'?"; then
            del_safe "$stack"
        else
            log INFO "Skipped $stack at the final step."
        fi
    done

    log PASS "Purge operations complete."
}

# =============================================================================
# 5. STACK OPERATIONS
# =============================================================================

stack_up() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            docker stack deploy -c "$f" "$stack_name" \
                && log PASS "Swarm stack '$stack_name' deployed." \
                || die "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            $csm_cmd compose -f "$f" up -d --remove-orphans \
                && log PASS "Stack '$stack_name' is up." \
                || die "Failed to bring up stack '$stack_name'."
            ;;
    esac
}

stack_down() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            docker stack rm "$stack_name" \
                && log PASS "Swarm stack '$stack_name' brought down (removed)." \
                || die "Failed to bring down Swarm stack '$stack_name'."
            ;;
        local)
            $csm_cmd compose -f "$f" down \
                && log PASS "Stack '$stack_name' brought down." \
                || die "Failed to bring down stack '$stack_name'."
            ;;
    esac
}

stack_bounce() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log INFO "Re-deploying Swarm stack '$stack_name'..."
            docker stack deploy -c "$f" "$stack_name" \
                && log PASS "Swarm stack '$stack_name' re-deployed." \
                || die "Failed to re-deploy Swarm stack '$stack_name'."
            ;;
        local)
            log INFO "Bouncing stack '$stack_name'..."
            stack_down "$stack_name"
            stack_up   "$stack_name"
            ;;
    esac
}

stack_start() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log WARN "Swarm does not support 'start' without redeployment. Running full deploy."
            docker stack deploy -c "$f" "$stack_name" \
                && log PASS "Swarm stack '$stack_name' deployed." \
                || die "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            $csm_cmd compose -f "$f" start \
                && log PASS "Stack '$stack_name' started." \
                || die "Failed to start stack '$stack_name'."
            ;;
    esac
}

stack_restart() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log WARN "Swarm does not support 'restart' without redeployment. Running full deploy."
            docker stack deploy -c "$f" "$stack_name" \
                && log PASS "Swarm stack '$stack_name' deployed." \
                || die "Failed to deploy Swarm stack '$stack_name'."
            ;;
        local)
            $csm_cmd compose -f "$f" restart \
                && log PASS "Stack '$stack_name' restarted." \
                || die "Failed to restart stack '$stack_name'."
            ;;
    esac
}

stack_stop() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log WARN "Swarm does not support 'stop' without removal. Executing full removal."
            docker stack rm "$stack_name" \
                && log PASS "Swarm stack '$stack_name' removed." \
                || die "Failed to remove Swarm stack '$stack_name'."
            ;;
        local)
            $csm_cmd compose -f "$f" stop \
                && log PASS "Stack '$stack_name' stopped." \
                || die "Failed to stop stack '$stack_name'."
            ;;
    esac
}

stack_update() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log INFO "Pulling latest images for '$stack_name'..."
            docker stack deploy -c "$f" "$stack_name" \
                && log PASS "Swarm stack '$stack_name' updated (redeployed)." \
                || die "Failed to update Swarm stack '$stack_name'."
            ;;
        local)
            log INFO "Pulling latest images for '$stack_name'..."
            $csm_cmd compose -f "$f" pull
            $csm_cmd compose -f "$f" up -d \
                && log PASS "Stack '$stack_name' updated." \
                || die "Failed to update stack '$stack_name'."
            ;;
    esac
}

update_via_watchtower() {
    local ct_name; ct_name="$(require_name "${1:-}")"
    container_exists "$ct_name" || die "Container '$ct_name' not found."
    log INFO "Updating container '$ct_name'..."
    $csm_cmd stop "$ct_name" \
        && $csm_cmd run --name "$ct_name-update" -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --run-once "$ct_name" \
        && log PASS "Container '$ct_name' updated." \
        && $csm_cmd rm "$ct_name-update" \
        && $csm_cmd start "$ct_name" \
        || die "Failed to update container '$ct_name'."
}

# =============================================================================
# 6. INFORMATION
# =============================================================================

stack_list() {
    [[ -d "$csm_dir" ]] || die "Stacks directory not found: $csm_dir"

    # Check if swarm is active
    local swarm_active=false
    if [[ "$csm_cmd" == "docker" ]]; then
        local swarm_state
        swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
        [[ "$swarm_state" == "active" ]] && swarm_active=true
    fi

    local -a valid_stacks=()
    local -a empty_dirs=()

    # Find all non-hidden directories and sort them into valid/empty arrays
    while IFS= read -r -d '' stack_dir; do
        local dir_name; dir_name="$(basename "$stack_dir")"
        if [[ -f "${stack_dir}/compose.yml" || -f "${stack_dir}/docker-compose.yml" ]]; then
            valid_stacks+=("$dir_name")
        else
            empty_dirs+=("$dir_name")
        fi
    done < <(find "$csm_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | sort -z)

    # Build set of deployed swarm stacks for quick lookup
    local -a swarm_stacks=()
    if $swarm_active; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && swarm_stacks+=("$s")
        done < <(docker stack ls 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    # Output Valid Stacks
    if [[ ${#valid_stacks[@]} -gt 0 ]]; then
        log INFO "Active stacks in ${csm_dir}:"
        for dir_name in "${valid_stacks[@]}"; do
            local stack_dir="${csm_dir}/${dir_name}"
            local status_color status_label scope_label

            # Check if deployed to swarm
            local is_swarm=false
            if $swarm_active; then
                for s in "${swarm_stacks[@]}"; do
                    [[ "$s" == "$dir_name" ]] && { is_swarm=true; break; }
                done
            fi

            if $is_swarm; then
                scope_label="swarm"
                status_color="${grn}"
                status_label="deployed"
            elif $csm_cmd compose -f "${stack_dir}/compose.yml" ps --services \
                --filter status=running 2>/dev/null | grep -q .; then
                scope_label="compose"
                status_color="${grn}"; status_label="running"
            else
                scope_label="compose"
                status_color="${ylw}"; status_label="stopped"
            fi

            printf "  %s%-24s%s [%s%s%s] %s%s%s\n" \
                "${cyn}" "$dir_name" "${rst}" \
                "${status_color}" "$status_label" "${rst}" \
                "${blu}" "$scope_label" "${rst}"
        done
    else
        log WARN "No valid stacks found in $csm_dir"
    fi

    # Output Empty/Broken Directories
    if [[ ${#empty_dirs[@]} -gt 0 ]]; then
        echo ""
        log WARN "Directories missing a compose file (empty or broken):"
        for dir_name in "${empty_dirs[@]}"; do
            printf "  %s%-24s%s [  %s%s%s  ]\n" \
                "${wht}" "$dir_name" "${rst}" \
                "${red}" "empty" "${rst}"
        done
    fi
}

stack_ps() {
    local engine; engine="${csm_cmd%% *}"

    # Check if swarm is active
    local swarm_active=false
    if [[ "$engine" == "docker" ]]; then
        local swarm_state
        swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")"
        [[ "$swarm_state" == "active" ]] && swarm_active=true
    fi

    {
        printf "%sCONTAINER ID  NAME  STATUS  PORTS%s\n" "${bld}" "${rst}"
        $csm_cmd ps --all --format "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | \
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

    # Show swarm services if active
    if $swarm_active; then
        local services
        services="$(docker stack ls 2>/dev/null | awk 'NR>1 {print $1}')"
        if [[ -n "$services" ]]; then
            echo ""
            log INFO "Swarm services:"
            while IFS= read -r svc; do
                printf "  %s%s%s\n" "${cyn}" "$svc" "${rst}"
                docker service ps "$svc" --no-trunc --format "table {{.Name}}\t{{.CurrentState}}\t{{.Node}}\t{{.DesiredState}}" 2>/dev/null | \
                    tail -n +2 | sed 's/^/    /'
            done <<< "$services"
        fi
    fi
}

stack_status() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            docker service ps "$stack_name"
            ;;
        local)
            $csm_cmd compose -f "$f" ps
            ;;
    esac
}

stack_validate() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log INFO "Swarm does not support config validation without deployment."
            ;;
        local)
            if $csm_cmd compose -f "$f" config -q 2>&1; then
                log PASS "Config valid: $f"
            else
                die "Config invalid: $f"
            fi
            ;;
    esac
}

stack_inspect() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            log INFO "Inspecting Swarm stack '$stack_name'..."
            docker stack ps "$stack_name"
            ;;
        local)
            log INFO "Inspecting stack '$stack_name'..."
            $csm_cmd compose -f "$f" config
            ;;
    esac
}

stack_logs() {
    local stack_name; stack_name="$(require_name "${1:-}")"
    local f; f="$(require_compose_file "$stack_name")"
    local lines="${2:-50}"
    detect_scope "$stack_name"
    case "$scope" in
        swarm)
            docker service logs --tail "$lines" -f "$stack_name"
            ;;
        local)
            $csm_cmd compose -f "$f" logs -f --tail="$lines"
            ;;
    esac
}

stack_cd() {
    local stack_name; stack_name="$(require_name "${1:-}")"
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
            $csm_cmd network ls \
                --format "{{.Name}}\t{{.Driver}}\t{{.Scope}}\t{{.ID}}" | \
                sort | column -ts $'\t'
            ;;
        host)
            printf "Host IP : %s\n" \
                "$(curl -fsSL ifconfig.me 2>/dev/null || echo 'unavailable')"
            ;;
        inspect)
            local net="${2:-${csm_net_name}}"
            $csm_cmd network inspect "$net"
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
                "csm_dir"      "$csm_dir"   \
                "csm_backup"   "$csm_backup"   \
                "csm_common"   "$csm_common"   \
                "csm_configs"  "$csm_configs"  \
                "csm_secrets"  "$csm_secrets"  \
                "csm_net_name" "$csm_net_name" \
                "csm_cmd"      "${csm_cmd:-<not detected>}"
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

manage_template() {
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
    rm | remove   <n>           Stop and remove containers in a stack (prompts)
    dt | delete   <n>           Stop and PERMANENTLY delete stack + all data (prompts)
    bu | backup   <n>           Tar-gz the stack directory to .backup/
    xx | purge    <n>           Purges all stacks inside ${csm_dir} - WARNING THIS IS FINAL

${bld}Stack Operations:${rst}
    u  | up       <n>           Start a stack  (compose start)
    st | start    <n>           Start a stack  (compose up -d)
    d  | down     <n>           Stop a stack   (compose down)
    sp | stop     <n>           Stop a stack   (compose stop)
    r  | restart  <n>           Restart a stack (compose restart)
    b  | bounce   <n>           Bring stack down then back up (full recreate)
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

    local cmd="${1:-}"
    [[ -z "$cmd" ]] && { show_help; exit 0; }
    shift || true

    case "$cmd" in
        -h|--help)    show_help; exit 0 ;;
        -v|--version) echo "CSM v${CSM_VERSION}"; exit 0 ;;
    esac

    load_config
    validate_config || true
    detect_compose_command

    case "$cmd" in
        c|create)       stack_create    "$@" ;; # create a new stack directory
        m|modify)       stack_modify    "$@" ;; # open a stack compose.yml in editor
        bu|backup)      stack_backup    "$@" ;; # create archive of stack folder
        dt|delete)      stack_delete    "$@" ;; # delete stack folder
        rm|remove)      stack_remove    "$@" ;; # container stop && container rm
        xx|purge)       stack_purge     "$@" ;; # force stop and force delete all stack files and data
        u|up)           stack_up        "$@" ;; # container up
        d|dn|down)      stack_down      "$@" ;; # container down
        b|bounce)       stack_bounce    "$@" ;; # container rm && container up
        st|start)       stack_start     "$@" ;; # container start
        sp|stop)        stack_stop      "$@" ;; # container stop
        r|rs|restart)   stack_restart   "$@" ;; # container stop and start
        rc|recreate)    stack_recreate  "$@" ;; # removes and recreates container folders
        ud|update)      stack_update    "$@" ;; # update container image and restart
        i|inspect)      stack_inspect   "$@" ;; # inspect container details
        l|ls|list)      stack_list           ;; # list active or all containers
        s|status)       stack_status    "$@" ;; # checks status of container/service
        v|validate)     stack_validate  "$@" ;; # validate compose syntax
        g|logs)         stack_logs      "$@" ;; # display container logs
        cd)             stack_cd        "$@" ;; # go to stack directory
        ps)             stack_ps             ;; # list stack containers
        net)            net_info        "$@" ;; # list container networks
        cfg|config)     manage_configs  "$@" ;; # check and edit config variables
        t|template)     manage_template "$@" ;; # list/download/update local template
        *) log FAIL "Unknown command: '$cmd'"; show_help; exit 1 ;;
    esac
}

main "$@"
