#!/bin/bash
# Container Stack Manager (CSM)
# A unified container stack management tool supporting docker and podman
# Author: Drauku
# Date: 2025-06-10
# License: MIT

# ============================================
# CONFIGURATION
# ============================================

# Git project file structure pre-installation:
# ./$SCRIPT_DIR/
# ├── default.conf
# ├── example.env
# ├── csm
# ├── csm_functions.sh
# └── csm_installer.sh

# File-structure post-installation:
# /srv/stacks/
# ├── .backup/
# │  └── <stackname>/
# │     └── <stackname>-yymmdd-hhmm.tar.gz
# ├── .common/
# │  ├── configs/
# │  │  ├── default.conf
# │  │  └── user.conf
# │  ├── csm
# │  ├── csm_functions.sh
# │  ├── example.env
# │  └── secrets/
# │     └── <secretname>.secret
# ├── <stackname>/
# |  ├── .env
# |  ├── compose.yml
# |  └── appdata/
# └── .../

set -euo pipefail

# 1. Directory variables
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
csm_backup="${CSM_ROOT_DIR}/backup"
csm_common="${CSM_ROOT_DIR}/common"
csm_stacks="${CSM_ROOT_DIR}/stacks"
csm_configs="${csm_common}/configs"
csm_secrets="${csm_common}/secrets"

readonly dir_mode="0770"
readonly auth_mode="0600"
readonly conf_mode="0660"

declare -A files_to_install=(
    ["${script_dir}/csm"]="${CSM_ROOT_DIR}/"
    ["${script_dir}/csm_functions.sh"]="${csm_common}/"
    ["${script_dir}/default.conf"]="${csm_configs}/"
)


# 2. Load configurations in order of precedence
if [[ -f "${HOME}/.csm/config" ]]; then
    source "${HOME}/.csm/config"
elif [[ -f "${script_dir}/user.conf" ]]; then
    source "${script_dir}/user.conf"
elif [[ -f "${script_dir}/default.conf" ]]; then
    source "${script_dir}/default.conf"
fi

# 3. Source core utilities
src1="${CSM_COMMON_DIR:-/srv/stacks/common}/csm_functions.sh"
src2="${script_dir}/csm_functions.sh"

if [[ -f "${src1}" ]]; then
    source "${src1}"
elif [[ -f "${src2}" ]]; then
    source "${src2}"
else
    log FAIL "Failed to load configuration, file not found: ${src1} or ${src2}"
    exit 1
fi

show_main_help() {
    cat << EOF
Container Stack Manager (CSM) v1.0.0

Usage: csm <command> [arguments]

Stack Lifecycle:
    c  | create <name>            Create a new stack
    m  | modify <name>            Edit stack configuration
    rm | remove <name>            Remove stack (keep data)
    dt | delete <name>            Delete stack and all data
    bu | backup <name>            Backup stack configuration

Stack Operations:
    u  | up | start <name>        Start a stack
    d  | dn | down | stop <name>  Stop a stack
    b  | bounce | recreate <name> Restart a stack
    r  | restart <name>           Restart a stack
    ud | update <name>            Update stack images

Information:
    l  | list                     List all stacks
    s  | status <name>            Show stack status
    v  | validate <name>          Validate stack configuration

Templates:
    t  | template <action>        Manage templates (list, add, remove, update)

Setup:
    -i | --install                Run initial installation setup

Options:
    -h | --help                   Show this help message
    -v | --version                Show version information
EOF
}

# Main function to handle command dispatching
main() {
    export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"

    # Initialize and validate config (functions defined in csm_functions.sh)
    if ! load_config 2>/dev/null; then
        log FAIL "Failed to load configuration"
        exit 1
    fi
    validate_config

    # Detect container runtime and compose wrapper globally
    detect_compose_command

    local cmd="${1:-}"
    local args=()
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_main_help; exit 0 ;;
            -v|--version) echo "CSM v1.0.0"; exit 0 ;;
            *) args+=("$1"); shift ;;
        esac
    done

    set -- "${args[@]}"

    case "$cmd" in
        c|create)                 create_stack "$@" ;;
        m|modify)                 modify_stack "$@" ;;
        rm|remove)                remove_stack "$@" ;;
        dt|delete)                delete_stack "$@" ;;
        bu|backup)                backup_stack "$@" ;;
        u|up|start)               up_stack "$@" ;;
        d|dn|down|stop)           down_stack "$@" ;;
        b|bounce|rc|recreate)     bounce_stack "$@" ;;
        r|rs|restart)             restart_stack "$@" ;;
        ud|update)                update_stack "$@" ;;
        l|ls|list)                list_stacks ;;
        s|status)                 status_stack "$@" ;;
        v|validate)               validate_stack "$@" ;;
        t|template)               manage_templates "$@" ;;
        cfg|config)               manage_configs "$@" ;;
        i|install)                install_csm ;;
        *)                        show_main_help; exit 1 ;;
    esac
}

main "$@"
