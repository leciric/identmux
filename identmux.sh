#!/usr/bin/env bash
# identmux — stateless interactive identity multiplexer
# Maps filesystem paths to user identities and authentication keys.
# https://github.com/leciric/identmux
#
# Usage:
#   curl -fsSL <url>/identmux.sh | bash                  # interactive setup
#   curl -fsSL <url>/identmux.sh | bash -s -- --apply    # reapply existing config
#   curl -fsSL <url>/identmux.sh | bash -s -- --config <url>  # load remote config
#   curl -fsSL <url>/identmux.sh | bash -s -- --export   # print config to stdout
#   curl -fsSL <url>/identmux.sh | bash -s -- --dry-run  # preview changes

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

readonly IDENTMUX_VERSION="0.1.0"
readonly CONFIG_DIR="${HOME}/.config/identmux"
readonly CONFIG_FILE="${CONFIG_DIR}/config.yaml"
readonly SSH_DIR="${HOME}/.ssh"
readonly SSH_CONFIG="${SSH_DIR}/config"
readonly GITCONFIG="${HOME}/.gitconfig"

readonly MANAGED_START="# >>> identmux managed start >>>"
readonly MANAGED_END="# <<< identmux managed end <<<"

# ─────────────────────────────────────────────────────────────────────────────
# Color / formatting
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    readonly C_BOLD='' C_DIM='' C_RESET=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

log_info()    { printf '%s[info]%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*" >&2; }
log_success() { printf '%s[ok]%s   %s\n'    "${C_GREEN}"  "${C_RESET}" "$*" >&2; }
log_warn()    { printf '%s[warn]%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error()   { printf '%s[err]%s  %s\n'    "${C_RED}"    "${C_RESET}" "$*" >&2; }

die() { log_error "$@"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Global state
# ─────────────────────────────────────────────────────────────────────────────

# Populated by yaml_parse / interactive wizard.
# IDENTITIES is a space-separated list of identity labels (e.g. "personal work").
IDENTITIES=""
DEFAULT_IDENTITY=""

# Per-identity data stored in associative arrays.
declare -A ID_NAME=()
declare -A ID_EMAIL=()
declare -A ID_SSH_KEY=()
declare -A ID_HOSTS=()   # pipe-separated list  "github.com|gitlab.com"
declare -A ID_PATHS=()   # pipe-separated list  "~/personal|~/oss"

# Runtime flags
DRY_RUN=0
NON_INTERACTIVE=0

# ─────────────────────────────────────────────────────────────────────────────
# Prompt helpers (interactive)
# ─────────────────────────────────────────────────────────────────────────────

# Read a line from /dev/tty so it works in a curl|bash pipe.
_read_tty() {
    local _var="$1"; shift
    # shellcheck disable=SC2229
    IFS= read -r "$@" "${_var}" </dev/tty
}

prompt_input() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "${default}" ]]; then
        printf '%s%s%s [%s]: ' "${C_BOLD}" "${prompt}" "${C_RESET}" "${default}" >&2
    else
        printf '%s%s%s: ' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
    fi
    _read_tty reply
    reply="${reply:-${default}}"
    printf '%s' "${reply}"
}

prompt_yesno() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "${default}" == "y" ]]; then
        printf '%s%s%s [Y/n]: ' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
    else
        printf '%s%s%s [y/N]: ' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
    fi
    _read_tty reply
    reply="${reply:-${default}}"
    [[ "${reply}" =~ ^[Yy] ]]
}

prompt_choice() {
    local prompt="$1"; shift
    local -a options=("$@")
    local i reply

    printf '\n%s%s%s\n' "${C_BOLD}" "${prompt}" "${C_RESET}" >&2
    for i in "${!options[@]}"; do
        printf '  %s%d)%s %s\n' "${C_CYAN}" $((i + 1)) "${C_RESET}" "${options[$i]}" >&2
    done
    printf 'Choice: ' >&2
    _read_tty reply
    reply="${reply:-1}"
    if ! [[ "${reply}" =~ ^[0-9]+$ ]] || (( reply < 1 || reply > ${#options[@]} )); then
        reply=1
    fi
    printf '%d' "${reply}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Minimal YAML parser
# ─────────────────────────────────────────────────────────────────────────────
# Handles ONLY the identmux config schema. Not a general-purpose YAML parser.
# Supports:  version, default, identities.<id>.{name,email,ssh_key,hosts[],paths[]}

yaml_parse() {
    local file="$1"
    [[ -f "${file}" ]] || die "Config file not found: ${file}"

    local line trimmed current_identity="" current_list="" indent
    IDENTITIES=""
    DEFAULT_IDENTITY=""
    ID_NAME=(); ID_EMAIL=(); ID_SSH_KEY=(); ID_HOSTS=(); ID_PATHS=()

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blank lines and comments
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "${trimmed}" || "${trimmed}" == \#* ]] && continue

        # Measure leading indent (number of spaces)
        indent="${line%%[![:space:]]*}"
        indent="${#indent}"

        # Top-level scalars (indent 0)
        if (( indent == 0 )); then
            current_identity=""
            current_list=""
            if [[ "${trimmed}" =~ ^version:[[:space:]]*(.+)$ ]]; then
                : # acknowledged, not stored
            elif [[ "${trimmed}" =~ ^default:[[:space:]]*(.+)$ ]]; then
                DEFAULT_IDENTITY="${BASH_REMATCH[1]}"
                DEFAULT_IDENTITY="${DEFAULT_IDENTITY//\"/}"
                DEFAULT_IDENTITY="${DEFAULT_IDENTITY//\'/}"
                DEFAULT_IDENTITY="${DEFAULT_IDENTITY%"${DEFAULT_IDENTITY##*[![:space:]]}"}"
            elif [[ "${trimmed}" == "identities:" ]]; then
                : # entering identities block
            fi
            continue
        fi

        # Identity label (indent 2)
        if (( indent == 2 )) && [[ "${trimmed}" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
            current_identity="${BASH_REMATCH[1]}"
            current_list=""
            IDENTITIES="${IDENTITIES:+${IDENTITIES} }${current_identity}"
            ID_HOSTS["${current_identity}"]=""
            ID_PATHS["${current_identity}"]=""
            continue
        fi

        # Identity fields (indent 4)
        if (( indent == 4 )) && [[ -n "${current_identity}" ]]; then
            current_list=""
            local val
            if [[ "${trimmed}" =~ ^name:[[:space:]]*(.+)$ ]]; then
                val="${BASH_REMATCH[1]}"; val="${val//\"/}"; val="${val//\'/}"
                val="${val%"${val##*[![:space:]]}"}"
                ID_NAME["${current_identity}"]="${val}"
            elif [[ "${trimmed}" =~ ^email:[[:space:]]*(.+)$ ]]; then
                val="${BASH_REMATCH[1]}"; val="${val//\"/}"; val="${val//\'/}"
                val="${val%"${val##*[![:space:]]}"}"
                ID_EMAIL["${current_identity}"]="${val}"
            elif [[ "${trimmed}" =~ ^ssh_key:[[:space:]]*(.+)$ ]]; then
                val="${BASH_REMATCH[1]}"; val="${val//\"/}"; val="${val//\'/}"
                val="${val%"${val##*[![:space:]]}"}"
                ID_SSH_KEY["${current_identity}"]="${val}"
            elif [[ "${trimmed}" == "hosts:" ]]; then
                current_list="hosts"
            elif [[ "${trimmed}" == "paths:" ]]; then
                current_list="paths"
            fi
            continue
        fi

        # List items (indent 6+)
        if (( indent >= 6 )) && [[ -n "${current_identity}" ]] && [[ -n "${current_list}" ]]; then
            if [[ "${trimmed}" =~ ^-[[:space:]]+(.+)$ ]]; then
                local item="${BASH_REMATCH[1]}"
                item="${item//\"/}"; item="${item//\'/}"
                item="${item%"${item##*[![:space:]]}"}"
                if [[ "${current_list}" == "hosts" ]]; then
                    local existing="${ID_HOSTS["${current_identity}"]:-}"
                    ID_HOSTS["${current_identity}"]="${existing:+${existing}|}${item}"
                elif [[ "${current_list}" == "paths" ]]; then
                    local existing="${ID_PATHS["${current_identity}"]:-}"
                    ID_PATHS["${current_identity}"]="${existing:+${existing}|}${item}"
                fi
            fi
            continue
        fi

    done < "${file}"

    # Validate
    if [[ -z "${IDENTITIES}" ]]; then
        die "No identities found in ${file}"
    fi
    if [[ -z "${DEFAULT_IDENTITY}" ]]; then
        # Use first identity as default
        DEFAULT_IDENTITY="${IDENTITIES%% *}"
        log_warn "No default identity set; using '${DEFAULT_IDENTITY}'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# YAML writer
# ─────────────────────────────────────────────────────────────────────────────

yaml_write() {
    local file="$1"
    mkdir -p "$(dirname "${file}")"

    {
        printf 'version: 1\n'
        printf 'default: %s\n\n' "${DEFAULT_IDENTITY}"
        printf 'identities:\n'

        local id
        for id in ${IDENTITIES}; do
            printf '  %s:\n' "${id}"
            printf '    name: "%s"\n'    "${ID_NAME[${id}]:-}"
            printf '    email: "%s"\n'   "${ID_EMAIL[${id}]:-}"
            printf '    ssh_key: "%s"\n' "${ID_SSH_KEY[${id}]:-}"

            printf '    hosts:\n'
            local hosts_str="${ID_HOSTS[${id}]:-}"
            if [[ -n "${hosts_str}" ]]; then
                local IFS='|'
                local h
                for h in ${hosts_str}; do
                    printf '      - "%s"\n' "${h}"
                done
            fi

            printf '    paths:\n'
            local paths_str="${ID_PATHS[${id}]:-}"
            if [[ -n "${paths_str}" ]]; then
                local IFS='|'
                local p
                for p in ${paths_str}; do
                    printf '      - "%s"\n' "${p}"
                done
            fi
            printf '\n'
        done
    } > "${file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Config management
# ─────────────────────────────────────────────────────────────────────────────

config_exists() {
    [[ -f "${CONFIG_FILE}" ]]
}

config_load() {
    yaml_parse "${CONFIG_FILE}"
}

config_save() {
    yaml_write "${CONFIG_FILE}"
    log_success "Config written to ${CONFIG_FILE}"
}

config_from_url() {
    local url="$1"
    log_info "Fetching config from ${url} ..."
    mkdir -p "${CONFIG_DIR}"
    if ! curl -fsSL "${url}" -o "${CONFIG_FILE}"; then
        die "Failed to fetch config from ${url}"
    fi
    log_success "Config saved to ${CONFIG_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH key management
# ─────────────────────────────────────────────────────────────────────────────

# Expand ~ at the start of a path
expand_tilde() {
    local p="$1"
    # shellcheck disable=SC2088
    if [[ "${p}" == "~/"* ]]; then
        printf '%s/%s' "${HOME}" "${p:2}"
    elif [[ "${p}" == "~" ]]; then
        printf '%s' "${HOME}"
    else
        printf '%s' "${p}"
    fi
}

ssh_key_exists() {
    local key_path
    key_path="$(expand_tilde "$1")"
    [[ -f "${key_path}" ]]
}

ssh_key_generate() {
    local key_path comment
    key_path="$(expand_tilde "$1")"
    comment="${2:-identmux}"

    if [[ -f "${key_path}" ]]; then
        log_warn "SSH key already exists: ${key_path} — skipping generation"
        return 0
    fi

    mkdir -p "$(dirname "${key_path}")"
    chmod 700 "$(dirname "${key_path}")"

    if ! command -v ssh-keygen &>/dev/null; then
        die "ssh-keygen not found. Please install OpenSSH."
    fi

    log_info "Generating SSH key: ${key_path}"
    if (( DRY_RUN )); then
        log_info "[dry-run] Would run: ssh-keygen -t ed25519 -C \"${comment}\" -f \"${key_path}\" -N \"\""
        return 0
    fi

    ssh-keygen -t ed25519 -C "${comment}" -f "${key_path}" -N "" -q
    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"
    log_success "Generated SSH key: ${key_path}"

    printf '\n%sPublic key:%s\n' "${C_BOLD}" "${C_RESET}" >&2
    cat "${key_path}.pub" >&2
    printf '\n' >&2
}

ssh_detect_existing() {
    local -a keys=()
    local f
    for f in "${SSH_DIR}"/id_*; do
        [[ -f "${f}" ]] || continue
        # Skip .pub files — we want private keys
        [[ "${f}" == *.pub ]] && continue
        keys+=("${f}")
    done
    printf '%s\n' "${keys[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Managed block helpers
# ─────────────────────────────────────────────────────────────────────────────

# Read a file and return everything OUTSIDE the managed block.
strip_managed_block() {
    local file="$1"
    [[ -f "${file}" ]] || return 0

    local in_block=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == "${MANAGED_START}" ]]; then
            in_block=1; continue
        fi
        if [[ "${line}" == "${MANAGED_END}" ]]; then
            in_block=0; continue
        fi
        if (( ! in_block )); then
            printf '%s\n' "${line}"
        fi
    done < "${file}"
}

# Write managed block + existing content to a file.
# The managed block is placed at the TOP (important for SSH config match order).
write_with_managed_block() {
    local file="$1" block_content="$2"

    local existing=""
    if [[ -f "${file}" ]]; then
        existing="$(strip_managed_block "${file}")"
        # Trim leading blank lines to prevent accumulation across reruns
        while [[ "${existing}" == $'\n'* ]]; do
            existing="${existing#$'\n'}"
        done
    fi

    mkdir -p "$(dirname "${file}")"

    {
        printf '%s\n' "${MANAGED_START}"
        printf '%s\n' "${block_content}"
        printf '%s\n' "${MANAGED_END}"
        if [[ -n "${existing}" ]]; then
            printf '\n%s\n' "${existing}"
        fi
    } > "${file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH config writer
# ─────────────────────────────────────────────────────────────────────────────

# Scan the unmanaged portion of ~/.ssh/config for Host entries that match any
# configured hostname. Emits a warning for each conflict found so the user
# knows their external definition may shadow or be shadowed by identmux entries.
detect_conflicting_ssh_hosts() {
    [[ -f "${SSH_CONFIG}" ]] || return 0

    # Collect all configured hostnames across every identity
    local all_hosts=()
    local id hosts_str hostname
    for id in ${IDENTITIES}; do
        hosts_str="${ID_HOSTS[${id}]:-}"
        [[ -z "${hosts_str}" ]] && continue
        local IFS='|'
        for hostname in ${hosts_str}; do
            unset IFS
            all_hosts+=("${hostname}")
        done
        unset IFS
    done

    [[ ${#all_hosts[@]} -eq 0 ]] && return 0

    # Read only the unmanaged lines of ~/.ssh/config
    local unmanaged
    unmanaged="$(strip_managed_block "${SSH_CONFIG}")"

    # Check each configured hostname against unmanaged Host lines
    local warned=0
    local h
    for h in "${all_hosts[@]}"; do
        # Match "Host <hostname>" or "Host <hostname> ..." (exact token, not substring)
        if printf '%s\n' "${unmanaged}" | grep -qE "^Host[[:space:]]+(\S+[[:space:]]+)*${h}([[:space:]]|$)"; then
            log_warn "Existing SSH host '${h}' found outside the identmux managed block — it may conflict with identity routing"
            warned=1
        fi
    done

    return 0
}

generate_ssh_config_block() {
    local block="" id host_alias hostname key_path

    for id in ${IDENTITIES}; do
        key_path="${ID_SSH_KEY[${id}]:-}"
        [[ -z "${key_path}" ]] && continue

        local hosts_str="${ID_HOSTS[${id}]:-}"
        [[ -z "${hosts_str}" ]] && continue

        local IFS='|'
        for hostname in ${hosts_str}; do
            unset IFS
            if [[ "${id}" == "${DEFAULT_IDENTITY}" ]]; then
                # Default identity gets the plain hostname entry
                block+="Host ${hostname}
    HostName ${hostname}
    User git
    IdentityFile ${key_path}
    IdentitiesOnly yes

"
            fi

            # All identities get an aliased entry
            host_alias="${hostname}-${id}"
            block+="Host ${host_alias}
    HostName ${hostname}
    User git
    IdentityFile ${key_path}
    IdentitiesOnly yes

"
        done
        unset IFS
    done

    printf '%s' "${block}"
}

apply_ssh_config() {
    local block
    block="$(generate_ssh_config_block)"

    if [[ -z "${block}" ]]; then
        log_warn "No SSH config entries to write (no keys or hosts defined)"
        return 0
    fi

    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"

    # Warn about any global Host entries outside the managed block that match
    # a configured hostname — these may interfere with identity routing.
    detect_conflicting_ssh_hosts

    if (( DRY_RUN )); then
        printf '\n%s--- ~/.ssh/config (managed block) ---%s\n' "${C_DIM}" "${C_RESET}" >&2
        printf '%s\n' "${MANAGED_START}" >&2
        printf '%s\n' "${block}" >&2
        printf '%s\n' "${MANAGED_END}" >&2
        return 0
    fi

    write_with_managed_block "${SSH_CONFIG}" "${block}"
    chmod 644 "${SSH_CONFIG}"
    log_success "SSH config updated: ${SSH_CONFIG}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Git config writer
# ─────────────────────────────────────────────────────────────────────────────

# Write per-identity gitconfig snippets in ~/.config/identmux/
write_identity_gitconfigs() {
    local id
    for id in ${IDENTITIES}; do
        local name="${ID_NAME[${id}]:-}"
        local email="${ID_EMAIL[${id}]:-}"
        [[ -z "${name}" && -z "${email}" ]] && continue

        local gitconfig_path="${CONFIG_DIR}/gitconfig-${id}"

        # Build url rewrite block for non-default identities only.
        # Each configured host gets an insteadOf rule covering both SSH and HTTPS
        # remotes, routing them to the identity-specific SSH alias.
        local url_block=""
        if [[ "${id}" != "${DEFAULT_IDENTITY}" ]]; then
            local hosts_str="${ID_HOSTS[${id}]:-}"
            if [[ -n "${hosts_str}" ]]; then
                local IFS='|'
                local hostname
                for hostname in ${hosts_str}; do
                    unset IFS
                    url_block+="
[url \"git@${hostname}-${id}:\"]
    insteadOf = git@${hostname}:
    insteadOf = https://${hostname}/
"
                done
                unset IFS
            fi
        fi

        if (( DRY_RUN )); then
            printf '\n%s--- %s ---%s\n' "${C_DIM}" "${gitconfig_path}" "${C_RESET}" >&2
            printf '[user]\n' >&2
            [[ -n "${name}" ]]  && printf '    name = %s\n' "${name}" >&2
            [[ -n "${email}" ]] && printf '    email = %s\n' "${email}" >&2
            if [[ -n "${url_block}" ]]; then
                printf '%s' "${url_block}" >&2
            fi
            continue
        fi

        mkdir -p "${CONFIG_DIR}"
        {
            printf '[user]\n'
            [[ -n "${name}" ]]  && printf '    name = %s\n' "${name}"
            [[ -n "${email}" ]] && printf '    email = %s\n' "${email}"
            if [[ -n "${url_block}" ]]; then
                printf '%s' "${url_block}"
            fi
        } > "${gitconfig_path}"
    done
}

generate_git_config_block() {
    local block="" id

    # Default identity user block
    local def_name="${ID_NAME[${DEFAULT_IDENTITY}]:-}"
    local def_email="${ID_EMAIL[${DEFAULT_IDENTITY}]:-}"
    if [[ -n "${def_name}" || -n "${def_email}" ]]; then
        block+="[user]
"
        [[ -n "${def_name}" ]]  && block+="    name = ${def_name}
"
        [[ -n "${def_email}" ]] && block+="    email = ${def_email}
"
        block+="
"
    fi

    # includeIf directives for each identity's paths
    for id in ${IDENTITIES}; do
        local paths_str="${ID_PATHS[${id}]:-}"
        [[ -z "${paths_str}" ]] && continue

        local gitconfig_path="${CONFIG_DIR}/gitconfig-${id}"
        local IFS='|'
        local p
        for p in ${paths_str}; do
            unset IFS
            # Expand tilde for gitdir pattern, ensure trailing slash
            local expanded
            expanded="$(expand_tilde "${p}")"
            [[ "${expanded}" != */ ]] && expanded="${expanded}/"

            block+="[includeIf \"gitdir:${expanded}\"]
    path = ${gitconfig_path}
"
        done
        unset IFS
    done

    printf '%s' "${block}"
}

apply_git_config() {
    if ! command -v git &>/dev/null; then
        log_warn "git not found; skipping .gitconfig integration"
        return 0
    fi

    write_identity_gitconfigs

    local block
    block="$(generate_git_config_block)"

    if [[ -z "${block}" ]]; then
        log_warn "No Git config entries to write (no name/email/paths defined)"
        return 0
    fi

    if (( DRY_RUN )); then
        printf '\n%s--- ~/.gitconfig (managed block) ---%s\n' "${C_DIM}" "${C_RESET}" >&2
        printf '%s\n' "${MANAGED_START}" >&2
        printf '%s\n' "${block}" >&2
        printf '%s\n' "${MANAGED_END}" >&2
        return 0
    fi

    write_with_managed_block "${GITCONFIG}" "${block}"
    log_success "Git config updated: ${GITCONFIG}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary / preview
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    printf '\n%s╔══════════════════════════════════════╗%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s║       identmux configuration         ║%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s╚══════════════════════════════════════╝%s\n\n' "${C_BOLD}" "${C_RESET}" >&2

    printf '%sDefault identity:%s %s\n\n' "${C_BOLD}" "${C_RESET}" "${DEFAULT_IDENTITY}" >&2

    local id
    for id in ${IDENTITIES}; do
        local marker=""
        [[ "${id}" == "${DEFAULT_IDENTITY}" ]] && marker=" ${C_GREEN}(default)${C_RESET}"
        printf '%s● %s%s%s\n' "${C_CYAN}" "${id}" "${C_RESET}" "${marker}" >&2
        printf '  Name:    %s\n' "${ID_NAME[${id}]:-<not set>}" >&2
        printf '  Email:   %s\n' "${ID_EMAIL[${id}]:-<not set>}" >&2
        printf '  SSH key: %s\n' "${ID_SSH_KEY[${id}]:-<not set>}" >&2

        printf '  Hosts:   ' >&2
        local hosts_str="${ID_HOSTS[${id}]:-}"
        if [[ -n "${hosts_str}" ]]; then
            printf '%s\n' "${hosts_str//|/, }" >&2
        else
            printf '<none>\n' >&2
        fi

        printf '  Paths:   ' >&2
        local paths_str="${ID_PATHS[${id}]:-}"
        if [[ -n "${paths_str}" ]]; then
            printf '%s\n' "${paths_str//|/, }" >&2
        else
            printf '<none>\n' >&2
        fi
        printf '\n' >&2
    done

    printf '%sFiles that will be modified:%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '  • %s\n' "${CONFIG_FILE}" >&2
    printf '  • %s\n' "${SSH_CONFIG}" >&2
    if command -v git &>/dev/null; then
        printf '  • %s\n' "${GITCONFIG}" >&2
        for id in ${IDENTITIES}; do
            printf '  • %s/gitconfig-%s\n' "${CONFIG_DIR}" "${id}" >&2
        done
    fi

    local id key_path
    for id in ${IDENTITIES}; do
        key_path="${ID_SSH_KEY[${id}]:-}"
        [[ -z "${key_path}" ]] && continue
        if ! ssh_key_exists "${key_path}"; then
            printf '  • %s %s(new key)%s\n' "$(expand_tilde "${key_path}")" "${C_YELLOW}" "${C_RESET}" >&2
        fi
    done
    printf '\n' >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Apply (core orchestrator)
# ─────────────────────────────────────────────────────────────────────────────

apply_config() {
    print_summary

    if (( ! NON_INTERACTIVE && ! DRY_RUN )); then
        if ! prompt_yesno "Apply this configuration?"; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # 1. Generate missing SSH keys
    local id key_path
    for id in ${IDENTITIES}; do
        key_path="${ID_SSH_KEY[${id}]:-}"
        [[ -z "${key_path}" ]] && continue
        if ! ssh_key_exists "${key_path}"; then
            ssh_key_generate "${key_path}" "${ID_EMAIL[${id}]:-identmux-${id}}"
        fi
    done

    # 2. Write config file
    if (( ! DRY_RUN )); then
        config_save
    else
        log_info "[dry-run] Would write config to ${CONFIG_FILE}"
    fi

    # 3. SSH config
    apply_ssh_config

    # 4. Git config
    apply_git_config

    # 5. Done
    printf '\n' >&2
    if (( DRY_RUN )); then
        log_info "Dry run complete. No files were modified."
    else
        log_success "identmux configuration applied successfully."
        printf '\n%sNext steps:%s\n' "${C_BOLD}" "${C_RESET}" >&2
        printf '  1. Add your public keys to your Git hosting providers.\n' >&2
        printf '  2. Repos under mapped paths will auto-use the correct Git identity.\n' >&2
        printf '\n' >&2

        if (( ! NON_INTERACTIVE )) && command -v git &>/dev/null; then
            if prompt_yesno "Update git remotes in existing repositories to use the configured SSH aliases?" "n"; then
                update_repo_remotes
            fi
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Remote URL updater
# ─────────────────────────────────────────────────────────────────────────────

# Extract the "user/repo" slug from any remote URL.
# Handles:  git@host:user/repo.git
#           git@host-alias:user/repo.git
#           https://host/user/repo.git
#           https://host/user/repo
_extract_slug() {
    local url="$1"
    local slug=""

    if [[ "${url}" =~ ^git@[^:]+:(.+)$ ]]; then
        slug="${BASH_REMATCH[1]}"
    elif [[ "${url}" =~ ^https?://[^/]+/(.+)$ ]]; then
        slug="${BASH_REMATCH[1]}"
    else
        printf ''
        return
    fi

    slug="${slug%.git}"
    printf '%s' "${slug}"
}

# Extract the bare hostname from a remote URL, stripping any identity alias
# suffix that identmux may have previously written (e.g. github.com-work →
# github.com). Resolution is done against the configured host list so we never
# read ~/.ssh/config.
#
# Returns empty string for unrecognised URL schemes.
_url_bare_host() {
    local url="$1"
    local raw=""

    if [[ "${url}" =~ ^git@([^:]+): ]]; then
        raw="${BASH_REMATCH[1]}"
    elif [[ "${url}" =~ ^https?://([^/]+)/ ]]; then
        raw="${BASH_REMATCH[1]}"
    else
        printf ''
        return
    fi

    # Walk every identity's host list and check whether `raw` equals a known
    # host or is a known host with an alias suffix appended (host-label).
    # Use a plain while-read loop to avoid any IFS side-effects.
    local id hosts_str hostname
    for id in ${IDENTITIES}; do
        hosts_str="${ID_HOSTS[${id}]:-}"
        [[ -z "${hosts_str}" ]] && continue
        while IFS= read -r hostname; do
            [[ -z "${hostname}" ]] && continue
            if [[ "${raw}" == "${hostname}" || "${raw}" == "${hostname}-"* ]]; then
                printf '%s' "${hostname}"
                return
            fi
        done < <(printf '%s\n' "${hosts_str//|/$'\n'}")
    done

    # Host not managed by identmux — signal to caller to skip this remote.
    printf ''
}

# Build the correct SSH alias URL for a given identity + bare hostname + slug.
# Every identity (including the default) uses the explicit alias form so that
# remotes are unambiguous and don't rely on SSH config fallthrough.
#   git@github.com-personal:user/repo.git
#   git@github.com-work:user/repo.git
_target_url() {
    local id="$1" hostname="$2" slug="$3"
    printf 'git@%s-%s:%s.git' "${hostname}" "${id}" "${slug}"
}

# Walk every configured identity path, find git repos, collect needed remote
# URL changes, show a summary, then apply them (or dry-run).
update_repo_remotes() {
    if ! command -v git &>/dev/null; then
        die "git not found; cannot update remotes"
    fi

    # Collect changes: parallel arrays
    local -a CHG_REPO=()
    local -a CHG_REMOTE=()
    local -a CHG_OLD=()
    local -a CHG_NEW=()

    local id
    for id in ${IDENTITIES}; do
        local paths_str="${ID_PATHS[${id}]:-}"
        [[ -z "${paths_str}" ]] && continue

        # Iterate paths for this identity (pipe-separated) without touching IFS
        local p
        while IFS= read -r p; do
            [[ -z "${p}" ]] && continue
            local base_dir
            base_dir="$(expand_tilde "${p}")"
            [[ -d "${base_dir}" ]] || continue

            # Find all git repos under base_dir at any depth
            local repo_dir
            while IFS= read -r repo_dir; do
                [[ -d "${repo_dir}" ]] || continue

                # Enumerate every remote in this repo
                local remote
                while IFS= read -r remote; do
                    [[ -z "${remote}" ]] && continue

                    local old_url
                    # Read the raw stored URL — bypass insteadOf rewrites which
                    # would make already-rewritten remotes appear correct.
                    old_url="$(git -C "${repo_dir}" config "remote.${remote}.url" 2>/dev/null)" || continue
                    [[ -z "${old_url}" ]] && continue

                    # Resolve the bare hostname from the config — no SSH config read
                    local bare_host
                    bare_host="$(_url_bare_host "${old_url}")"
                    [[ -z "${bare_host}" ]] && continue  # not a managed host, skip

                    # Confirm this host is actually listed for the current identity
                    local host_listed=0
                    local h
                    while IFS= read -r h; do
                        [[ "${h}" == "${bare_host}" ]] && host_listed=1 && break
                    done < <(printf '%s\n' "${ID_HOSTS[${id}]:-}" | tr '|' '\n')
                    (( host_listed )) || continue

                    local slug
                    slug="$(_extract_slug "${old_url}")"
                    [[ -z "${slug}" ]] && continue

                    local new_url
                    new_url="$(_target_url "${id}" "${bare_host}" "${slug}")"

                    # Only record if a change is actually needed
                    if [[ "${old_url}" != "${new_url}" ]]; then
                        CHG_REPO+=("${repo_dir%/}")
                        CHG_REMOTE+=("${remote}")
                        CHG_OLD+=("${old_url}")
                        CHG_NEW+=("${new_url}")
                    fi
                done < <(git -C "${repo_dir}" remote 2>/dev/null)
            done < <(find "${base_dir}" -mindepth 1 -name ".git" -type d 2>/dev/null | sed 's|/.git$||' | sort)
        done < <(printf '%s\n' "${paths_str//|/$'\n'}")
    done

    if (( ${#CHG_REPO[@]} == 0 )); then
        log_info "All remote URLs are already up to date. Nothing to change."
        return 0
    fi

    # Print summary table
    printf '\n%s╔══════════════════════════════════════╗%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s║       remote URL updates             ║%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s╚══════════════════════════════════════╝%s\n\n' "${C_BOLD}" "${C_RESET}" >&2

    local i
    for i in "${!CHG_REPO[@]}"; do
        printf '%s● %s%s  (%s)\n' "${C_CYAN}" "$(basename "${CHG_REPO[$i]}")" "${C_RESET}" "${CHG_REMOTE[$i]}" >&2
        printf '  %sold:%s %s\n' "${C_DIM}" "${C_RESET}" "${CHG_OLD[$i]}" >&2
        printf '  %snew:%s %s\n' "${C_GREEN}" "${C_RESET}" "${CHG_NEW[$i]}" >&2
        printf '\n' >&2
    done

    if (( DRY_RUN )); then
        log_info "[dry-run] Would update ${#CHG_REPO[@]} remote(s). No changes made."
        return 0
    fi

    if (( ! NON_INTERACTIVE )); then
        if ! prompt_yesno "Apply these ${#CHG_REPO[@]} remote update(s)?"; then
            log_info "Skipped remote updates."
            return 0
        fi
    fi

    local failed=0
    for i in "${!CHG_REPO[@]}"; do
        if git -C "${CHG_REPO[$i]}" remote set-url "${CHG_REMOTE[$i]}" "${CHG_NEW[$i]}" 2>/dev/null; then
            log_success "Updated ${CHG_REMOTE[$i]} in $(basename "${CHG_REPO[$i]}"): ${CHG_NEW[$i]}"
        else
            log_error "Failed to update ${CHG_REMOTE[$i]} in ${CHG_REPO[$i]}"
            (( failed++ )) || true
        fi
    done

    if (( failed > 0 )); then
        log_warn "${failed} remote(s) could not be updated."
    else
        log_success "All remote URLs updated successfully."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Export
# ─────────────────────────────────────────────────────────────────────────────

export_config() {
    if ! config_exists; then
        die "No config found at ${CONFIG_FILE}. Run identmux interactively first."
    fi
    cat "${CONFIG_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Interactive wizard
# ─────────────────────────────────────────────────────────────────────────────

wizard_collect_identity() {
    local label="$1"

    printf '\n%s── Identity: %s ──%s\n' "${C_BOLD}" "${label}" "${C_RESET}" >&2

    local name email ssh_key hosts_input paths_input

    name="$(prompt_input "  Display name" "")"
    email="$(prompt_input "  Email" "")"

    # SSH key
    # shellcheck disable=SC2088
    local default_key="~/.ssh/id_ed25519_${label}"
    printf '\n' >&2
    local key_choice
    key_choice="$(prompt_choice "  SSH key for '${label}':" \
        "Generate new key (${default_key})" \
        "Use existing key")"

    if (( key_choice == 1 )); then
        ssh_key="${default_key}"
    else
        # Let user pick from detected keys or type a path
        local -a existing_keys=()
        while IFS= read -r k; do
            [[ -n "${k}" ]] && existing_keys+=("${k}")
        done < <(ssh_detect_existing)

        if (( ${#existing_keys[@]} > 0 )); then
            printf '\n  Detected existing keys:\n' >&2
            local i
            for i in "${!existing_keys[@]}"; do
                printf '    %s%d)%s %s\n' "${C_CYAN}" $((i + 1)) "${C_RESET}" "${existing_keys[$i]}" >&2
            done
            printf '    %s%d)%s Enter a custom path\n' "${C_CYAN}" $(( ${#existing_keys[@]} + 1 )) "${C_RESET}" >&2
            printf '  Choice: ' >&2
            local kchoice
            _read_tty kchoice
            kchoice="${kchoice:-1}"
            if (( kchoice > 0 && kchoice <= ${#existing_keys[@]} )); then
                ssh_key="${existing_keys[$((kchoice - 1))]}"
                # Convert back to ~ form
                ssh_key="${ssh_key/#${HOME}/\~}"
            else
                ssh_key="$(prompt_input "  SSH key path" "${default_key}")"
            fi
        else
            ssh_key="$(prompt_input "  SSH key path" "${default_key}")"
        fi
    fi

    # Hosts
    printf '\n' >&2
    hosts_input="$(prompt_input "  SSH hosts (comma-separated)" "github.com")"
    # Normalize: strip spaces, replace commas with pipes
    hosts_input="${hosts_input// /}"
    hosts_input="${hosts_input//,/|}"

    # Paths
    printf '\n' >&2
    # shellcheck disable=SC2088
    paths_input="$(prompt_input "  Project directories (comma-separated)" "~/${label}")"
    paths_input="${paths_input// /}"
    paths_input="${paths_input//,/|}"

    # Store
    IDENTITIES="${IDENTITIES:+${IDENTITIES} }${label}"
    ID_NAME["${label}"]="${name}"
    ID_EMAIL["${label}"]="${email}"
    ID_SSH_KEY["${label}"]="${ssh_key}"
    ID_HOSTS["${label}"]="${hosts_input}"
    ID_PATHS["${label}"]="${paths_input}"
}

run_wizard() {
    printf '\n%s╔══════════════════════════════════════╗%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s║         identmux setup wizard        ║%s\n' "${C_BOLD}" "${C_RESET}" >&2
    printf '%s╚══════════════════════════════════════╝%s\n\n' "${C_BOLD}" "${C_RESET}" >&2

    printf 'This wizard will configure multiple Git/SSH identities\n' >&2
    printf 'mapped to your project directories.\n\n' >&2

    # Reset state
    IDENTITIES=""
    DEFAULT_IDENTITY=""
    ID_NAME=(); ID_EMAIL=(); ID_SSH_KEY=(); ID_HOSTS=(); ID_PATHS=()

    # Collect identities
    local num_identities
    num_identities="$(prompt_input "How many identities to configure?" "2")"
    if ! [[ "${num_identities}" =~ ^[0-9]+$ ]] || (( num_identities < 1 )); then
        num_identities=2
    fi

    local i label
    for (( i = 1; i <= num_identities; i++ )); do
        printf '\n' >&2
        if (( i == 1 )); then
            label="$(prompt_input "Label for identity ${i}" "personal")"
        elif (( i == 2 )); then
            label="$(prompt_input "Label for identity ${i}" "work")"
        else
            label="$(prompt_input "Label for identity ${i}" "identity-${i}")"
        fi
        # Sanitize label: lowercase, alphanumeric + dash + underscore
        label="${label,,}"
        label="${label//[^a-z0-9_-]/-}"

        wizard_collect_identity "${label}"
    done

    # Pick default
    printf '\n' >&2
    if (( num_identities == 1 )); then
        DEFAULT_IDENTITY="${IDENTITIES}"
    else
        local -a id_array=()
        local id
        for id in ${IDENTITIES}; do
            id_array+=("${id}")
        done
        local def_choice
        def_choice="$(prompt_choice "Select default identity:" "${id_array[@]}")"
        DEFAULT_IDENTITY="${id_array[$((def_choice - 1))]}"
    fi

    # Apply
    apply_config
}

# ─────────────────────────────────────────────────────────────────────────────
# Existing config handler
# ─────────────────────────────────────────────────────────────────────────────

handle_existing_config() {
    log_info "Existing config found: ${CONFIG_FILE}"
    printf '\n' >&2

    local choice
    choice="$(prompt_choice "What would you like to do?" \
        "Reapply existing configuration" \
        "Overwrite with new configuration" \
        "Edit interactively (re-run wizard)" \
        "Show current configuration" \
        "Update git remotes in existing repositories")"

    case "${choice}" in
        1)
            config_load
            apply_config
            ;;
        2)
            run_wizard
            ;;
        3)
            run_wizard
            ;;
        4)
            config_load
            print_summary
            ;;
        5)
            config_load
            update_repo_remotes
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Usage / help
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<USAGE
${C_BOLD}identmux${C_RESET} v${IDENTMUX_VERSION} — identity multiplexer for development environments

${C_BOLD}USAGE${C_RESET}
    curl -fsSL <url>/identmux.sh | bash                              Interactive setup
    curl -fsSL <url>/identmux.sh | bash -s -- --apply               Reapply config
    curl -fsSL <url>/identmux.sh | bash -s -- --config <url>        Load remote config
    curl -fsSL <url>/identmux.sh | bash -s -- --export              Print config
    curl -fsSL <url>/identmux.sh | bash -s -- --update-remotes      Update existing repo remotes
    curl -fsSL <url>/identmux.sh | bash -s -- --dry-run             Preview changes
    ./identmux.sh [options]                                          Run directly

${C_BOLD}OPTIONS${C_RESET}
    --apply             Reapply existing configuration non-interactively
    --config <url>      Fetch config from URL and apply
    --export            Print current config.yaml to stdout
    --update-remotes    Update git remote URLs in existing repos to match SSH aliases
    --dry-run           Show what would be changed without modifying files
    --help              Show this help message
    --version           Print version

${C_BOLD}CONFIG${C_RESET}
    ${CONFIG_FILE}

${C_BOLD}MANAGED FILES${C_RESET}
    ${SSH_CONFIG}
    ${GITCONFIG}
    ${CONFIG_DIR}/gitconfig-*

USAGE
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────────────────────

preflight() {
    # Warn if running as root
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        log_warn "Running as root. identmux is intended for regular user accounts."
        if (( ! NON_INTERACTIVE )); then
            if ! prompt_yesno "Continue anyway?" "n"; then
                exit 1
            fi
        fi
    fi

    # Check for ssh-keygen
    if ! command -v ssh-keygen &>/dev/null; then
        log_warn "ssh-keygen not found. SSH key generation will not be available."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    local mode="auto"       # auto | apply | config | export | update-remotes | help | version
    local config_url=""

    # Parse arguments
    while (( $# > 0 )); do
        case "$1" in
            --apply)
                mode="apply"
                NON_INTERACTIVE=1
                shift
                ;;
            --update-remotes)
                mode="update-remotes"
                NON_INTERACTIVE=1
                shift
                ;;
            --config)
                mode="config"
                NON_INTERACTIVE=1
                [[ -z "${2:-}" ]] && die "--config requires a URL argument"
                config_url="$2"
                shift 2
                ;;
            --export)
                mode="export"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --help|-h)
                mode="help"
                shift
                ;;
            --version|-v)
                mode="version"
                shift
                ;;
            *)
                die "Unknown option: $1 (try --help)"
                ;;
        esac
    done

    # Dispatch
    case "${mode}" in
        help)
            usage
            exit 0
            ;;
        version)
            printf 'identmux %s\n' "${IDENTMUX_VERSION}"
            exit 0
            ;;
        export)
            export_config
            exit 0
            ;;
        config)
            preflight
            config_from_url "${config_url}"
            config_load
            apply_config
            exit 0
            ;;
        apply)
            preflight
            if ! config_exists; then
                die "No config found at ${CONFIG_FILE}. Run identmux interactively first."
            fi
            config_load
            apply_config
            exit 0
            ;;
        update-remotes)
            preflight
            if ! config_exists; then
                die "No config found at ${CONFIG_FILE}. Run identmux interactively first."
            fi
            config_load
            update_repo_remotes
            exit 0
            ;;
        auto)
            preflight
            if (( DRY_RUN )) && config_exists; then
                config_load
                apply_config
                exit 0
            fi
            if config_exists; then
                handle_existing_config
            else
                run_wizard
            fi
            exit 0
            ;;
    esac
}

main "$@"
