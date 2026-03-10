#!/bin/bash
#!/bin/bash
# File: csm_install.sh
# Container Stack Manager - Installer

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

# 1. Permission validation
if [[ "$(id -u)" -eq 0 ]]; then
    var_sudo=""
elif command -v sudo >/dev/null 2>&1; then
    var_sudo="sudo"
else
    echo "ERROR: Installation requires root or sudo privileges" >&2
    exit 1
fi

# 1. Directory setup
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CSM_ROOT_DIR="${CSM_ROOT_DIR:-/srv/stacks}"
csm_backup="${CSM_ROOT_DIR}/.backup"
csm_common="${CSM_ROOT_DIR}/.common"
csm_stacks="${CSM_ROOT_DIR}/stacks"
csm_configs="${csm_common}/configs"
csm_secrets="${csm_common}/secrets"

readonly dir_mode="0770"
readonly auth_mode="0600"
readonly conf_mode="0660"

declare -A files_to_install=(
    ["${script_dir}/csm_functions.sh"]="${csm_common}/"
    ["${script_dir}/csm"]="${CSM_ROOT_DIR}/"
    ["${script_dir}/default.conf"]="${csm_configs}/"
)

# 3. Utility functions
# if [[ -f "${script_dir}/csm_functions.sh" ]]; then
#     source "${script_dir}/csm_functions.sh"
# else
#     echo "ERROR: csm_functions.sh not found." >&2
#     exit 1
# fi

color_setup() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        red=$(tput setaf 1)
        grn=$(tput setaf 2)
        ylw=$(tput setaf 3)
        blu=$(tput setaf 4)
        mgn=$(tput setaf 5)
        cyn=$(tput setaf 6)
        bld=$(tput bold)
        rst=$(tput sgr0)
    else
        red="" ylw="" grn="" cyn="" blu="" mgn="" bld="" rst=""
    fi
}
color_setup

log() {
    local level="$1"
    local message="$2"
    case "$level" in
        FAIL) echo -e "${red}${bld} FAIL  >> ${message}${rst}" >&2 ;;
        WARN) echo -e "${ylw}${bld} WARN  >> ${message}${rst}" >&2 ;;
        INFO) echo -e "${cyn}${bld} INFO  >> ${message}${rst}" ;;
        DONE) echo -e "${grn}${bld} DONE  >> ${message}${rst}" ;;
        *)    echo -e "${blu}${bld} DEBUG >> ${message}${rst}" ;;
    esac
}

install_secure() {
    local src="$1"
    local tgt="$2"
    local mode="$3"
    local is_dir="${4:-false}"

    if [[ "$is_dir" == "true" ]]; then
        if [[ ! -d "$tgt" ]]; then
            $var_sudo mkdir -p "$tgt"
            $var_sudo chmod "$mode" "$tgt"
            log INFO "Created directory: $tgt"
        fi
    elif [[ -f "$src" ]]; then
        $var_sudo cp "$src" "$tgt"
        $var_sudo chmod "$mode" "${tgt}$(basename "$src")"
        log INFO "Installed: $(basename "$src") to $tgt"
    fi
}

directories_setup() {
    log INFO "Setting up directory structure..."
    local dirs=("$CSM_ROOT_DIR" "$csm_common" "$csm_backup" "$csm_stacks" "$csm_configs")

    for d in "${dirs[@]}"; do
        install_secure "" "$d" "$dir_mode" "true"
    done

    # Secrets gets restricted mode
    install_secure "" "$csm_secrets" "0700" "true"
}

setup_files() {
    log INFO "Installing core files..."
    for src in "${!files_to_install[@]}"; do
        if [[ -f "$src" ]]; then
            install_secure "$src" "${files_to_install[$src]}" "0770"
        else
            log WARN "Source file missing during install: $src"
        fi
    done

    local bin_dir="/usr/local/bin"
    if [[ ! -L "${bin_dir}/csm" ]]; then
        $var_sudo ln -sf "${CSM_ROOT_DIR}/csm" "${bin_dir}/csm"
        log INFO "Created symlink: ${bin_dir}/csm"
    fi
}

install_csm() {
    log INFO "Starting CSM Installation to ${CSM_ROOT_DIR}"

    directories_setup
    setup_files

    local target_uid="${SUDO_UID:-$(id -u)}"
    local target_gid="${SUDO_GID:-$(id -g)}"

    $var_sudo chown -R "${target_uid}:${target_gid}" "$CSM_ROOT_DIR"
    log DONE "Installation complete! Use 'csm --help' to get started."
}

install_csm
