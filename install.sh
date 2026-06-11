#!/usr/bin/env bash
# 3DX Gateway — Linux installer (initial setup).
#
# Usage:
#   sudo bash install.sh                       interactive, all defaults
#   sudo bash install.sh --help                show flags
#   curl -sSL <raw>/install.sh | sudo bash     one-line install from public manifest repo
#
# Unattended mode (CI/automation):
#   sudo bash install.sh \
#     --install-dir /opt/3dx-gateway \
#     --hostname gateway.acme.local \
#     --port 443 \
#     --tls auto \
#     --license /tmp/acme.lic \
#     --telemetry on \
#     --helper \
#     --yes
#
# Idempotent: refuses to run if the install dir already contains a
# docker-compose.yml (use the dedicated `upgrade.sh` for in-place reconfig).
#
# Tested on:
#   Ubuntu 22.04 / 24.04
#   Debian 12
#   RHEL 9 / Rocky Linux 9
#
# What gets installed:
#   /opt/3dx-gateway/                  (configurable via --install-dir)
#     ├── docker-compose.yml           main stack: app + postgres
#     ├── docker-compose.tls.yml       Caddy overlay (TLS mode auto|letsencrypt)
#     ├── docker-compose.helper.yml    Apply-Update host helper overlay (optional)
#     ├── Caddyfile                    reverse-proxy config (TLS modes only)
#     ├── compose.env                  COMPOSE_FILES read by the systemd unit
#     ├── .env                         POSTGRES_PASSWORD + ports + hostname
#     ├── license.lic                  customer license (copied from --license path)
#     └── data/                        bind-mounted app data
#   /etc/systemd/system/3dx-gateway.service     auto-start on boot (static)
#   /usr/local/bin/3dx-gateway-helper.sh        if --helper
#   /etc/systemd/system/3dx-gateway-helper.*    if --helper

set -euo pipefail

INSTALLER_VERSION="1.4.0"
PUBLIC_REPO_BASE="https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main"
GHCR_IMAGE_BACKEND="ghcr.io/solfins-dev/3dx-gateway:latest"

# Sensible defaults
DEFAULT_INSTALL_DIR="/opt/3dx-gateway"
DEFAULT_PORT_TLS=443
DEFAULT_PORT_HTTP=5000
DEFAULT_CADDY_HTTP_PORT=80   # host port mapped to Caddy's :80 (redirect + local-CA download)
MIN_DISK_GB=5
MIN_RAM_MB=1800   # 2 GB rated, allow some slack for VMs that report 1900-ish

# CLI flag values (filled by parse_args)
ARG_INSTALL_DIR=""
ARG_HOSTNAME=""
ARG_PORT=""
ARG_HTTP_PORT=""        # host port for Caddy :80 (TLS modes); "0" disables; "" = auto
ARG_SKIP_FIREWALL=0     # 0 | 1
ARG_TLS=""              # auto | letsencrypt | none
ARG_LICENSE=""
ARG_TELEMETRY=""        # on | off
ARG_HELPER=0            # 0 | 1
ARG_YES=0               # 0 | 1 (skip confirmation prompts)
ARG_INSTALL_DOCKER=""   # "" | yes | no
ARG_DRY_RUN=0

# Effective values (filled by prompts or flags)
INSTALL_DIR=""
HOSTNAME_FQDN=""
APP_PORT=""
HTTP_PORT=""
TLS_MODE=""
LICENSE_PATH=""
TELEMETRY_ENABLED=""
INSTALL_HELPER=0
POSTGRES_PASSWORD=""
CONFIG_PROTECTOR_SEED=""

# Install slug — derived from basename(INSTALL_DIR). All container_name,
# systemd unit, and helper socket names are namespaced by this so two
# install.sh runs at different dirs land side-by-side without colliding
# on Docker's global container-name registry or systemd's unit registry.
# Default install dir 'opt/3dx-gateway' -> slug '3dx-gateway' (= existing
# behaviour for the first/only install).
INSTALL_SLUG=""

# ANSI escape sequences — use $'...' (ANSI-C quoting) so the byte 0x1B is
# embedded literally. Single-quoted '\033' is the 4-character string "\033"
# which only printf %b would interpret; cat <<EOF would echo it verbatim.
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'

#─── Output helpers ──────────────────────────────────────────────────────

step()    { printf "%b\n" "${C_BOLD}${C_CYAN}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
substep() { printf "%b\n" "    $*"; }
ok()      { printf "%b\n" "    ${C_GREEN}✓${C_RESET} $*"; }
warn()    { printf "%b\n" "    ${C_YELLOW}!${C_RESET} $*"; }
fail()    { printf "%b\n" "    ${C_RED}✗${C_RESET} $*" >&2; }
die()     { fail "$*"; exit 1; }
hr()      { printf "%b\n" "${C_DIM}─────────────────────────────────────────────────────────${C_RESET}"; }

print_banner() {
    cat <<EOF

${C_BOLD}${C_CYAN}3DX Gateway Installer v${INSTALLER_VERSION}${C_RESET}
${C_DIM}One-shot Linux setup. Solfins-dev/3dx-gateway-updates.${C_RESET}

EOF
}

#─── Argument parsing ────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: sudo bash install.sh [flags]

Flags:
  --install-dir PATH       Install location (default: $DEFAULT_INSTALL_DIR)
  --hostname HOST          Gateway FQDN workstations will use (default: auto-detect)
  --port N                 HTTPS port (default: $DEFAULT_PORT_TLS) or HTTP if --tls none.
                           If busy, auto-falls-back to a free port (8443 family)
                           UNLESS pinned with --port.
  --http-port N            Host port mapped to Caddy's :80 site (HTTP->HTTPS redirect +
                           local-CA download), TLS modes only (default: 80; auto-falls-back
                           to 8080 family if busy; 0 disables the :80 site).
  --skip-firewall          Don't open firewall ports (ufw/firewalld). Default: open the
                           published ports if a firewall is active.
  --tls MODE               TLS mode: auto | letsencrypt | none (default: auto)
                              auto:        Caddy with local CA (recommended for LAN)
                              letsencrypt: Caddy with Let's Encrypt (public hostname required)
                              none:        plain HTTP (you provide reverse proxy)
  --license PATH           License file to copy in (OPTIONAL -- the gateway starts in
                           "awaiting license" mode if absent; drop the real one in later)
  --telemetry on|off       Anonymous hourly version ping (default: on)
  --helper                 Install Apply Update host helper (one-click backend update)
  --install-docker yes|no  Auto-install Docker if missing (default: ask)
  --yes, -y                Skip "are you sure?" confirmations
  --dry-run                Show what would happen, don't make changes
  --help                   This message

Examples:
  # Interactive (all defaults):
  sudo bash install.sh

  # Unattended:
  sudo bash install.sh -y --hostname gateway.example.com \\
       --license /tmp/example.lic --helper

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-dir)      ARG_INSTALL_DIR="$2"; shift 2 ;;
            --hostname)         ARG_HOSTNAME="$2"; shift 2 ;;
            --port)             ARG_PORT="$2"; shift 2 ;;
            --http-port)        ARG_HTTP_PORT="$2"; shift 2 ;;
            --skip-firewall)    ARG_SKIP_FIREWALL=1; shift ;;
            --tls)              ARG_TLS="$2"; shift 2 ;;
            --license)          ARG_LICENSE="$2"; shift 2 ;;
            --telemetry)        ARG_TELEMETRY="$2"; shift 2 ;;
            --helper)           ARG_HELPER=1; shift ;;
            --install-docker)   ARG_INSTALL_DOCKER="$2"; shift 2 ;;
            --yes|-y)           ARG_YES=1; shift ;;
            --dry-run)          ARG_DRY_RUN=1; shift ;;
            --help|-h)          usage ;;
            *)                  die "Unknown flag: $1 (use --help)" ;;
        esac
    done
}

#─── Pre-flight ──────────────────────────────────────────────────────────

require_root() {
    [[ $EUID -eq 0 ]] || die "Re-run with sudo: sudo bash $0 $*"
}

check_os() {
    step "Checking OS"
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release — unsupported OS."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|rhel|rocky|almalinux|centos|fedora) ok "$PRETTY_NAME" ;;
        *) warn "$PRETTY_NAME — not on the verified-supported list; proceeding at your own risk." ;;
    esac
}

check_docker() {
    step "Checking Docker"
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            local v
            v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
            ok "Docker $v (daemon running)"
        else
            warn "Docker binary found but daemon isn't responding."
            if [[ $ARG_YES -eq 1 || $(prompt_yn "Try \`systemctl start docker\` now?" "y") == "y" ]]; then
                systemctl start docker || die "Failed to start docker daemon."
                ok "docker daemon started"
            else
                die "Docker daemon must be running before install."
            fi
        fi
    else
        warn "Docker not installed."
        local do_install=$ARG_INSTALL_DOCKER
        if [[ -z "$do_install" ]]; then
            do_install=$(prompt_yn "Install Docker now via the official get.docker.com script?" "y")
        fi
        if [[ "$do_install" == "yes" || "$do_install" == "y" ]]; then
            install_docker
        else
            die "Docker is required. Install it first: https://docs.docker.com/engine/install/"
        fi
    fi

    # docker compose v2 — MUST be the plugin form, not the v1 binary
    if docker compose version &>/dev/null; then
        ok "docker compose v$(docker compose version --short)"
    else
        die "docker compose v2 plugin missing. Install docker-compose-plugin (apt/dnf) or upgrade Docker."
    fi
}

install_docker() {
    substep "Running https://get.docker.com (this takes 1-3 min)..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed + enabled at boot"
}

check_disk() {
    step "Checking free disk"
    local target="${ARG_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    local check_at="$target"
    # If target doesn't exist, check its parent (or / as last resort)
    while [[ ! -d "$check_at" && "$check_at" != "/" ]]; do
        check_at=$(dirname "$check_at")
    done
    local free_kb
    free_kb=$(df -k "$check_at" | awk 'NR==2 {print $4}')
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if (( free_gb < MIN_DISK_GB )); then
        die "Only ${free_gb} GB free at $check_at; need ${MIN_DISK_GB} GB minimum."
    fi
    ok "${free_gb} GB free at $check_at"
}

check_ram() {
    step "Checking RAM"
    local total_mb
    total_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    if (( total_mb < MIN_RAM_MB )); then
        warn "${total_mb} MB RAM; recommend ≥ 2048 MB. Postgres + app may swap heavily under load."
    else
        ok "${total_mb} MB RAM"
    fi
}

check_port_free() {
    local port=$1
    # Use ss preferentially, fall back to netstat
    if command -v ss &>/dev/null; then
        ! ss -tlnH "sport = :$port" 2>/dev/null | grep -q ":$port"
    elif command -v netstat &>/dev/null; then
        ! netstat -tln 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"
    else
        # No port check tool — assume free, surface warning
        warn "Neither 'ss' nor 'netstat' available; cannot check port $port. Proceeding."
        return 0
    fi
}

#─── Interactive prompts ─────────────────────────────────────────────────

# prompt_yn QUESTION DEFAULT
# DEFAULT is 'y' or 'n'. Echoes 'y' or 'n' on stdout.
prompt_yn() {
    local question="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    if [[ $ARG_YES -eq 1 ]]; then
        echo "$default"
        return
    fi
    local answer
    read -r -p "    $question $hint " answer </dev/tty
    answer=${answer:-$default}
    case "${answer,,}" in
        y|yes) echo "y" ;;
        *)     echo "n" ;;
    esac
}

# prompt_text QUESTION DEFAULT
prompt_text() {
    local question="$1"
    local default="${2:-}"
    if [[ $ARG_YES -eq 1 ]]; then
        echo "$default"
        return
    fi
    local hint=""
    [[ -n "$default" ]] && hint=" [$default]"
    local answer
    read -r -p "    $question$hint: " answer </dev/tty
    echo "${answer:-$default}"
}

prompt_install_dir() {
    step "Install location"
    INSTALL_DIR=${ARG_INSTALL_DIR:-$(prompt_text "Install directory" "$DEFAULT_INSTALL_DIR")}
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
        die "An install already exists at $INSTALL_DIR (docker-compose.yml present). Remove it first or use a different --install-dir."
    fi
    derive_slug
    ok "Will install to: $INSTALL_DIR (slug: $INSTALL_SLUG)"
}

derive_slug() {
    # Map basename(INSTALL_DIR) to a Docker/systemd-friendly slug.
    # Allowed chars: [a-z0-9-_]. Anything else collapses to '-'. Multiple
    # consecutive dashes are squeezed; leading/trailing dashes stripped.
    local raw
    raw=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]')
    INSTALL_SLUG=$(echo "$raw" | tr -c 'a-z0-9_-' '-' | sed 's/-\+/-/g; s/^-\|-$//g')
    if [[ -z "$INSTALL_SLUG" ]]; then
        INSTALL_SLUG="3dx-gateway"
    fi
}

detect_existing_install() {
    step "Checking for existing 3DX Gateway artifacts on this host"
    local existing_containers
    existing_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E '^(3dx-gateway|bom-explorer)' || true)
    local existing_units
    existing_units=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '/3dx-gateway|bom-explorer/ {print $1}' || true)
    local our_unit_exists=0
    if systemctl list-unit-files "${INSTALL_SLUG}.service" --no-legend 2>/dev/null | grep -q "${INSTALL_SLUG}.service"; then
        our_unit_exists=1
    fi

    # Also check for orphan volumes from a removed prior install at this same
    # slug. Postgres only initialises POSTGRES_PASSWORD when its data dir is
    # empty -- inheriting an old pgdata volume + a freshly-generated password
    # in .env means EVERY app->db connection 28P01s and the app crashloops.
    local orphan_volumes
    orphan_volumes=$(docker volume ls --format '{{.Name}}' 2>/dev/null \
        | grep -E "^${INSTALL_SLUG}_(pgdata|app_data|caddy_data|caddy_config)$" || true)

    if [[ -z "$existing_containers" && -z "$existing_units" && -z "$orphan_volumes" ]]; then
        ok "No prior 3DX Gateway / bom-explorer install detected"
        return 0
    fi

    if [[ -n "$orphan_volumes" ]]; then
        warn "Orphan volumes from prior install at slug '${INSTALL_SLUG}' detected:"
        echo "$orphan_volumes" | sed 's/^/      volume:    /'
        substep ""
        substep "If left in place, postgres will reuse the OLD pgdata directory which has the"
        substep "OLD POSTGRES_PASSWORD baked into pg_hba.conf -- the freshly-generated password"
        substep "in .env won't match and the app will crashloop with FATAL: 28P01."
        if [[ $ARG_YES -eq 1 ]]; then
            warn "(--yes mode) WIPING orphan volumes for clean install."
            for v in $orphan_volumes; do docker volume rm "$v" >/dev/null 2>&1 || true; done
            ok "Orphan volumes removed"
        else
            local yn
            yn=$(prompt_yn "Wipe these volumes (RECOMMENDED for fresh install; loses any prior DB data)?" "y")
            if [[ "$yn" == "y" ]]; then
                for v in $orphan_volumes; do
                    docker volume rm "$v" >/dev/null 2>&1 || warn "Could not remove $v (may be in use)"
                done
                ok "Orphan volumes removed"
            else
                warn "Keeping orphan volumes. WARNING: app may crashloop if pgdata password mismatches."
                substep "If that happens: sudo systemctl stop ${INSTALL_SLUG}; docker volume rm ${INSTALL_SLUG}_pgdata; sudo systemctl start ${INSTALL_SLUG}"
            fi
        fi
    fi

    warn "Existing artifacts detected (this install will run side-by-side):"
    if [[ -n "$existing_containers" ]]; then
        echo "$existing_containers" | sed 's/^/      container:  /'
    fi
    if [[ -n "$existing_units" ]]; then
        echo "$existing_units" | sed 's/^/      systemd:    /'
    fi
    substep ""
    substep "This install will use slug '${INSTALL_SLUG}':"
    substep "  containers: ${INSTALL_SLUG}-app, ${INSTALL_SLUG}-db$([[ "$TLS_MODE" != "none" ]] && echo ", ${INSTALL_SLUG}-caddy")"
    substep "  systemd:    ${INSTALL_SLUG}.service"
    substep "  port:       ${APP_PORT} (must differ from existing instances; install.sh checks this next)"
    if [[ $our_unit_exists -eq 1 ]]; then
        die "A systemd unit '${INSTALL_SLUG}.service' is already installed. Remove it first ('systemctl disable --now ${INSTALL_SLUG}; rm /etc/systemd/system/${INSTALL_SLUG}.service; systemctl daemon-reload') or pick a different --install-dir."
    fi
    if [[ $ARG_YES -eq 0 ]]; then
        local yn
        yn=$(prompt_yn "Proceed with parallel install?" "y")
        [[ "$yn" == "y" ]] || die "Cancelled."
    fi
}

prompt_hostname() {
    step "Gateway hostname"
    HOSTNAME_FQDN=${ARG_HOSTNAME:-$(prompt_text "Hostname (URL workstations will use)" "$(detect_fqdn)")}
    ok "Hostname: $HOSTNAME_FQDN"
}

# Best-effort FQDN detection. `hostname --fqdn` is unreliable -- on hosts
# without a proper /etc/hosts entry or DNS PTR, it returns the bare short
# name. Try a series of sources before falling back to it.
detect_fqdn() {
    local cand short search

    # 1) hostname --fqdn returns a value with a dot.
    cand=$(hostname --fqdn 2>/dev/null || true)
    if [[ "$cand" == *.* ]]; then
        echo "$cand"; return
    fi

    # 2) hostname -A lists all FQDNs the kernel knows (one per IPv4/IPv6 addr).
    cand=$(hostname -A 2>/dev/null | tr ' ' '\n' | grep -m1 '\.' || true)
    if [[ -n "$cand" ]]; then
        echo "$cand"; return
    fi

    # 3) short hostname + first `search` domain from /etc/resolv.conf.
    short=$(hostname 2>/dev/null)
    search=$(awk '/^[ \t]*search[ \t]+/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    if [[ -n "$short" && -n "$search" ]]; then
        echo "${short}.${search}"; return
    fi

    # 4) bare short hostname -- caller will likely want to override.
    echo "${short:-localhost}"
}

prompt_tls_mode() {
    step "TLS mode"
    if [[ -n "$ARG_TLS" ]]; then
        TLS_MODE="$ARG_TLS"
    elif [[ $ARG_YES -eq 1 ]]; then
        TLS_MODE="auto"
    else
        cat <<EOF
    1) auto         Caddy with local CA (recommended for LAN). Self-signed,
                    workstations install /caddy-ca.crt once.
    2) letsencrypt  Caddy with Let's Encrypt (needs public DNS + ports 80/443).
    3) none         No TLS. You bring your own reverse proxy.
EOF
        local choice
        choice=$(prompt_text "Choose mode (1/2/3)" "1")
        case "$choice" in
            1|auto)        TLS_MODE="auto" ;;
            2|letsencrypt) TLS_MODE="letsencrypt" ;;
            3|none)        TLS_MODE="none" ;;
            *) die "Unknown TLS mode: $choice" ;;
        esac
    fi
    ok "TLS: $TLS_MODE"
}

# Echo the first bindable port from the args; non-zero exit if none free.
find_free_port() {
    local p
    for p in "$@"; do
        if check_port_free "$p"; then echo "$p"; return 0; fi
    done
    return 1
}

prompt_port() {
    step "Application port"
    local suggested=$DEFAULT_PORT_TLS
    [[ "$TLS_MODE" == "none" ]] && suggested=$DEFAULT_PORT_HTTP
    local pinned=0
    [[ -n "$ARG_PORT" ]] && pinned=1
    local requested=${ARG_PORT:-$(prompt_text "Port (will be checked for availability)" "$suggested")}
    [[ "$requested" =~ ^[0-9]+$ ]] || die "Invalid port: $requested"
    (( requested > 0 && requested < 65536 )) || die "Port out of range: $requested"
    if check_port_free "$requested"; then
        APP_PORT=$requested
        ok "Port $APP_PORT is free"
        return 0
    fi
    # Busy. Auto-fall-back UNLESS the operator pinned a specific --port (then we
    # respect it and stop, never silently moving a port they asked for). We
    # never stop the other service.
    warn "Port $requested is already in use."
    if (( pinned )); then
        die "Port $requested is in use. Free it or pass a different --port (\`ss -tlnp | grep :$requested\`). The installer never stops other services."
    fi
    local candidates
    if [[ "$TLS_MODE" == "none" ]]; then candidates="5000 5001 8081 8082 9080"; else candidates="8443 9443 8444 10443"; fi
    # shellcheck disable=SC2086
    APP_PORT=$(find_free_port $candidates) || \
        die "No free fallback port found (tried: $candidates). Free a port or pass --port N."
    ok "Using port $APP_PORT instead (the server already serves on $requested). Workstations connect on port $APP_PORT."
}

# Caddy's HTTP port (container :80) backs the HTTP->HTTPS redirect + the
# /caddy-ca.crt download. Default host port 80; if taken (existing nginx/apache),
# fall back; --http-port 0 disables the :80 site (CA served over HTTPS only).
# Let's Encrypt needs 80 for the ACME HTTP-01 challenge -- warn, don't move it.
# TLS modes only.
resolve_http_port() {
    if [[ "$TLS_MODE" == "none" ]]; then HTTP_PORT=0; return 0; fi
    step "HTTP port (Caddy redirect + local-CA download)"
    if [[ "$ARG_HTTP_PORT" == "0" ]]; then
        HTTP_PORT=0
        ok "HTTP port disabled (--http-port 0); CA served over HTTPS only."
        return 0
    fi
    local requested=${ARG_HTTP_PORT:-$DEFAULT_CADDY_HTTP_PORT}
    [[ "$requested" =~ ^[0-9]+$ ]] || die "Invalid --http-port: $requested"
    if check_port_free "$requested"; then
        HTTP_PORT=$requested
        ok "HTTP port $requested is free"
        return 0
    fi
    warn "HTTP port $requested is already in use."
    if [[ "$TLS_MODE" == "letsencrypt" ]]; then
        warn "Let's Encrypt needs port 80 reachable for the ACME HTTP-01 challenge."
        warn "Leaving Caddy bound to 80; make sure the host forwards external :80 to it, or cert issuance fails."
        HTTP_PORT=80
        return 0
    fi
    if [[ -n "$ARG_HTTP_PORT" ]]; then
        die "HTTP port $requested is in use. Pass a free --http-port, or --http-port 0 to disable. The installer never stops other services."
    fi
    # shellcheck disable=SC2086
    HTTP_PORT=$(find_free_port 8080 8081 8088 8090 8888) || HTTP_PORT=0
    if [[ "$HTTP_PORT" == "0" ]]; then
        warn "No free HTTP port found; disabling Caddy's :80 site. The local CA will be served over HTTPS (curl -k / trust-on-first-use)."
    else
        ok "Using HTTP port $HTTP_PORT for the redirect + CA download (host's port 80 is taken)."
    fi
}

prompt_license() {
    step "License file"
    # License is delivered out-of-band by Solfins (email) and is NOT bundled
    # with the installer. It's also OPTIONAL at install time -- the gateway
    # starts in an "awaiting license" state if license.lic is empty; the
    # customer can drop the real file in later + restart the service. This
    # decouples ordering license from "I want to spin up the stack now".
    LICENSE_PATH=${ARG_LICENSE:-$(prompt_text "Path to license.lic from Solfins (leave empty if you'll add it later)" "")}
    if [[ -z "$LICENSE_PATH" ]]; then
        ok "License: will be added later (gateway starts in 'awaiting license' state)"
        return
    fi
    [[ -f "$LICENSE_PATH" ]] || die "License file not found: $LICENSE_PATH"
    ok "License found: $LICENSE_PATH ($(stat -c%s "$LICENSE_PATH") bytes)"
}

prompt_telemetry() {
    step "Telemetry"
    if [[ -n "$ARG_TELEMETRY" ]]; then
        TELEMETRY_ENABLED=$ARG_TELEMETRY
    else
        cat <<EOF
    Anonymous hourly ping with version + opaque license hash.
    No BOM data, no credentials, no usage. See INSTALL.md "Privacy & telemetry"
    for the full payload. Toggleable later in Settings.
EOF
        TELEMETRY_ENABLED=$(prompt_yn "Enable telemetry?" "y")
        [[ "$TELEMETRY_ENABLED" == "y" ]] && TELEMETRY_ENABLED=on || TELEMETRY_ENABLED=off
    fi
    ok "Telemetry: $TELEMETRY_ENABLED"
}

prompt_helper() {
    step "Apply Update host helper"
    if [[ $ARG_HELPER -eq 1 ]]; then
        INSTALL_HELPER=1
    elif [[ $ARG_YES -eq 1 ]]; then
        # Unattended (--yes) without explicit --helper: SKIP. The helper
        # modifies global systemd state outside the install dir (writes
        # /etc/systemd/system/3dx-gateway-helper*, drops an override.conf
        # that points at the install dir). Automated installs shouldn't
        # touch global state without explicit consent — pass --helper
        # to opt in.
        INSTALL_HELPER=0
    else
        cat <<EOF
    Installs a tiny systemd-socket-activated helper at /run/3dx-gateway-helper.sock
    that lets the web UI's Settings → Updates card apply backend updates with a
    single click (the container can't restart itself). Without it, the UI falls
    back to a copy-SSH-command UX.
EOF
        local yn
        yn=$(prompt_yn "Install helper?" "y")
        [[ "$yn" == "y" ]] && INSTALL_HELPER=1 || INSTALL_HELPER=0
    fi
    ok "Helper: $([[ $INSTALL_HELPER -eq 1 ]] && echo install || echo skip)"
}

#─── File writing ────────────────────────────────────────────────────────

generate_secrets() {
    step "Generating Postgres password"
    # openssl rand -hex N emits 2N hex chars (0-9a-f) — alnum only, no shell
    # metacharacters, no SIGPIPE-vs-pipefail trap. 32 hex chars = 128 bits of
    # entropy which is plenty for a Postgres password.
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    ok "Generated 32-char password (saved to .env mode 600 after write)"

    step "Generating ConfigProtector seed"
    # ConfigProtector (backend/Services/ConfigProtector.cs) AES-256-encrypts
    # sensitive appsettings.json values (Pantheon passwords etc.). The key is
    # derived from this seed; without a stable seed, the code falls back to
    # Environment.MachineName, which inside Docker = container hostname =
    # random container ID. Every `docker compose up -d` recreate (= every
    # Apply Update) hands the new container a different MachineName, the
    # derived key changes, and previously-encrypted ENC: values become
    # unreadable -- the UI shows blank password fields and the user has to
    # re-enter every connection credential. Setting ConfigProtector__Seed in
    # the container env pins the key derivation to a stable per-install
    # secret that survives recreates. 64 hex chars = 256 bits.
    #
    # On re-install (.env already present): PRESERVE the existing seed.
    # appsettings.json is bind-mounted and survives orphan-volume wipe, so its
    # ENC: values are still encrypted with the original seed. Regenerating
    # the seed here would silently lose every encrypted password the customer
    # had set (same failure mode as the Apply Update bug this seed exists to
    # fix). POSTGRES_PASSWORD does NOT get preserved because pgdata is wiped
    # on the orphan-volumes branch above; the two have inverse retention.
    local existing_seed=""
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        existing_seed=$(grep -E '^CONFIG_PROTECTOR_SEED=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    if [[ -n "$existing_seed" ]]; then
        CONFIG_PROTECTOR_SEED="$existing_seed"
        ok "Preserved existing seed from .env (appsettings.json ENC: values stay readable)"
    else
        CONFIG_PROTECTOR_SEED=$(openssl rand -hex 32)
        ok "Generated 64-char seed (saved to .env mode 600 after write)"
    fi
}

write_compose_yml() {
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
# Generated by 3dx-gateway install.sh v${INSTALLER_VERSION}. Customer can edit but
# regeneration via reinstall will overwrite.

services:
  app:
    image: ${GHCR_IMAGE_BACKEND}
    container_name: ${INSTALL_SLUG}-app
    restart: unless-stopped
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ConnectionStrings__BomExplorer: "Host=postgres;Port=5432;Database=bom_explorer;Username=bomapp;Password=\${POSTGRES_PASSWORD}"
      Telemetry__Enabled: "$([[ $TELEMETRY_ENABLED == on ]] && echo true || echo false)"
      # Email-OTP onboarding path -- off by default; flip via .env once
      # Solfins has wired up the M365 SMTP secrets on the Worker side.
      Licensing__RequestEnabled: "\${LICENSING_REQUEST_ENABLED:-false}"
      # Path to the CadBridge ZIP inside the container (matches the bind
      # mount below). Backend's /api/downloads/CadBridge-Setup.zip endpoint
      # uses this; without it, the dev fallback (/cadbridge/publish/...)
      # doesn't exist in production images and the endpoint returns
      # "CadBridge installer not built yet".
      CadBridgeInstaller__Path: /app/installers/CadBridge-Setup.zip
      # ConfigProtector seed -- stable per-install secret read at container
      # start to derive the AES-256 key for ENC: values in appsettings.json.
      # MUST persist across Apply Updates or every encrypted password in
      # appsettings.json (Pantheon main + DB credentials etc.) becomes
      # unreadable and the customer has to re-type. .env survives container
      # recreates because docker compose reads it from the host fs.
      ConfigProtector__Seed: \${CONFIG_PROTECTOR_SEED}
EOF

    # When NOT using a TLS overlay, expose the port directly on the host.
    # With TLS overlay, Caddy fronts it on $APP_PORT and the app stays
    # container-internal at 5000.
    if [[ "$TLS_MODE" == "none" ]]; then
        cat >> "$INSTALL_DIR/docker-compose.yml" <<EOF
    ports:
      - "${APP_PORT}:5000"
EOF
    fi

    cat >> "$INSTALL_DIR/docker-compose.yml" <<EOF
    volumes:
      - app_data:/app/data
      # license.lic is bind-mounted RW so the first-run wizard can write
      # a customer-uploaded license back to disk. Backend only writes via
      # signature-validated paths -- a bind-mount RW is not the security
      # surface here, the signed-license requirement is.
      - ./license.lic:/app/license.lic
      # appsettings.json is bind-mounted RW so every Settings UI change
      # (Pantheon credentials, field mappings, webhooks, etc.) persists on
      # the host across docker compose pull + recreate. WITHOUT this mount,
      # all customer settings live in the writable container layer and
      # vanish on the first Apply Update.
      - ./appsettings.json:/app/appsettings.json
      # CadBridge ZIP is fetched once at install time + refreshed by Apply
      # Update (Settings -> Updates -> CadBridge). Backend serves it via
      # /api/downloads/CadBridge-Setup.zip with server-url.txt injection.
      - ./installers/CadBridge-Setup.zip:/app/installers/CadBridge-Setup.zip:ro
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/api/license/status"]
      interval: 30s
      timeout: 5s
      retries: 3

  postgres:
    image: postgres:16-alpine
    container_name: ${INSTALL_SLUG}-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: bom_explorer
      POSTGRES_USER: bomapp
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bomapp -d bom_explorer"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
  app_data:
EOF
}

write_caddy_overlay() {
    # Publish the HTTPS port always; publish the Caddy HTTP port (host HTTP_PORT
    # -> container 80) only when we secured one. HTTP_PORT=0 means the host's 80
    # was taken and no free alternative was found -> Caddy runs HTTPS-only.
    local http_map=""
    if [[ "$HTTP_PORT" != "0" ]]; then
        http_map=$'\n      - "'"${HTTP_PORT}"':80"'
    fi
    cat > "$INSTALL_DIR/docker-compose.tls.yml" <<EOF
# Caddy reverse proxy overlay — TLS termination.
services:
  caddy:
    image: caddy:2.9-alpine
    container_name: ${INSTALL_SLUG}-caddy
    restart: unless-stopped
    ports:
      - "${APP_PORT}:443"${http_map}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app

volumes:
  caddy_data:
  caddy_config:
EOF

    # Caddyfile content depends on TLS mode
    if [[ "$TLS_MODE" == "letsencrypt" ]]; then
        cat > "$INSTALL_DIR/Caddyfile" <<EOF
${HOSTNAME_FQDN} {
    reverse_proxy app:5000
}
EOF
    else
        # tls internal -- local CA. Global auto_https disable_redirects so Caddy's
        # automatic HTTP->HTTPS redirect doesn't shadow /caddy-ca.crt on the HTTP
        # port (that 308 returns a 0-byte body and breaks the CadBridge CA
        # bootstrap). CA handler is on the HTTPS site too, so CadBridge's HTTPS
        # (TOFU) fallback works when the HTTP port is remapped or disabled.
        cat > "$INSTALL_DIR/Caddyfile" <<EOF
{
    auto_https disable_redirects
}

${HOSTNAME_FQDN} {
    tls internal
    handle /caddy-ca.crt {
        root * /data/caddy/pki/authorities/local
        rewrite * /root.crt
        file_server
    }
    handle {
        reverse_proxy app:5000
    }
}
EOF
        # Explicit http://<host> site for the HTTP-port CA download + redirect,
        # only when we have an HTTP port. Use \`http://\${HOSTNAME_FQDN}\` (not a
        # bare \`:80\`, which auto-HTTPS still shadows). The redirect lives in a
        # catch-all \`handle {}\` so the specific \`handle /caddy-ca.crt\` wins
        # (Caddy orders a top-level \`redir\` before \`handle\`).
        if [[ "$HTTP_PORT" != "0" ]]; then
            cat >> "$INSTALL_DIR/Caddyfile" <<EOF

# Expose the local CA over HTTP so first-time workstations can fetch it.
http://${HOSTNAME_FQDN} {
    handle /caddy-ca.crt {
        root * /data/caddy/pki/authorities/local
        rewrite * /root.crt
        file_server
    }
    handle {
        redir https://${HOSTNAME_FQDN}{uri}
    }
}
EOF
        fi
    fi
}

write_helper_overlay() {
    cat > "$INSTALL_DIR/docker-compose.helper.yml" <<EOF
# Apply Update host helper bind-mount overlay.
# Prereq: scripts/host/install-helper.sh ran successfully (this script does it
# automatically when --helper is set).
services:
  app:
    volumes:
      - type: bind
        source: /run/3dx-gateway-helper.sock
        target: /var/run/3dx-gateway-helper.sock
        bind:
          create_host_path: false
EOF
}

write_env() {
    cat > "$INSTALL_DIR/.env" <<EOF
# 3DX Gateway environment — generated $(date -Iseconds) by install.sh v${INSTALLER_VERSION}.
# Keep this file out of version control; POSTGRES_PASSWORD + CONFIG_PROTECTOR_SEED are sensitive.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
# CONFIG_PROTECTOR_SEED -- per-install stable secret for ConfigProtector
# AES key derivation. DO NOT regenerate; rotating this invalidates every
# ENC: value in appsettings.json (Pantheon passwords etc.) and the user
# has to re-type every credential.
CONFIG_PROTECTOR_SEED=${CONFIG_PROTECTOR_SEED}
HOSTNAME=${HOSTNAME_FQDN}
APP_PORT=${APP_PORT}
TLS_MODE=${TLS_MODE}
TELEMETRY=${TELEMETRY_ENABLED}
# Onboarding email-OTP path. Default false: customers install via direct
# .lic upload (or pre-install --license). Flip to "true" after Solfins
# admin wires up the M365 SMTP path, then \`systemctl restart ${INSTALL_SLUG}\`.
LICENSING_REQUEST_ENABLED=false
EOF
    chmod 600 "$INSTALL_DIR/.env"
}

compute_compose_files() {
    # Returns the customer's docker-compose flag list, e.g.
    #   -f docker-compose.yml -f docker-compose.tls.yml -f docker-compose.helper.yml
    local compose_files="-f docker-compose.yml"
    [[ "$TLS_MODE" != "none" ]] && compose_files="$compose_files -f docker-compose.tls.yml"
    [[ $INSTALL_HELPER -eq 1 ]] && compose_files="$compose_files -f docker-compose.helper.yml"
    echo "$compose_files"
}

write_compose_env() {
    # systemd EnvironmentFile reader: KEY=VALUE per line. Values containing
    # spaces MUST be wrapped in double quotes or systemd splits on the first
    # space and silently drops the rest of the assignment (per
    # reference_systemd_environment_quoting). Use double-quoted form here.
    local compose_files
    compose_files=$(compute_compose_files)
    cat > "$INSTALL_DIR/compose.env" <<EOF
# 3DX Gateway compose flags -- read by 3dx-gateway.service at start time.
# Edit and run:  sudo systemctl restart 3dx-gateway
# to apply a new overlay set (e.g. adding -f docker-compose.staging.yml).
# Values with spaces MUST be double-quoted, or systemd splits them.
COMPOSE_FILES="${compose_files}"
EOF
    chmod 644 "$INSTALL_DIR/compose.env"
}

write_systemd_unit() {
    # Static unit -- customer-specific compose flags live in compose.env, not
    # baked into ExecStart. Adding a new overlay (e.g. docker-compose.staging.yml)
    # is then a one-line edit + `systemctl restart`; the unit itself never
    # needs to change. Unit name is namespaced by INSTALL_SLUG so multiple
    # parallel installs don't collide.
    #
    # Note on $COMPOSE_FILES (no braces): systemd ${VAR} substitutes as a SINGLE
    # argument (no word splitting), while $VAR splits on whitespace. We need
    # the split form so each -f docker-compose.* becomes its own argv entry to
    # docker compose. Using ${VAR} resulted in compose seeing one giant
    # filename "-f docker-compose.yml -f ...".
    cat > "/etc/systemd/system/${INSTALL_SLUG}.service" <<EOF
[Unit]
Description=3DX Gateway (${INSTALL_SLUG}) -- Solfins customer distribution
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/compose.env
ExecStart=/usr/bin/docker compose -p ${INSTALL_SLUG} \$COMPOSE_FILES up -d
ExecStop=/usr/bin/docker compose -p ${INSTALL_SLUG} \$COMPOSE_FILES down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

#─── Action ──────────────────────────────────────────────────────────────

write_files() {
    step "Writing files to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    write_compose_yml
    ok "docker-compose.yml"
    if [[ "$TLS_MODE" != "none" ]]; then
        write_caddy_overlay
        ok "docker-compose.tls.yml + Caddyfile ($TLS_MODE)"
    fi
    if [[ $INSTALL_HELPER -eq 1 ]]; then
        write_helper_overlay
        ok "docker-compose.helper.yml"
    fi
    write_env
    ok ".env (mode 600)"
    if [[ -n "$LICENSE_PATH" ]]; then
        cp "$LICENSE_PATH" "$INSTALL_DIR/license.lic"
        chmod 644 "$INSTALL_DIR/license.lic"
        ok "license.lic copied"
    else
        # Empty placeholder so the bind-mount in docker-compose.yml has
        # something to point at. Backend's LicenseService will see a 0-byte
        # file and report "license invalid"; the web UI then shows the
        # "awaiting license" state until the real file is dropped in.
        : > "$INSTALL_DIR/license.lic"
        chmod 644 "$INSTALL_DIR/license.lic"
        ok "license.lic placeholder (empty -- copy the real one from Solfins later)"
    fi
    mkdir -p "$INSTALL_DIR/data"
    fetch_cadbridge_zip
    seed_appsettings_if_missing
}

seed_appsettings_if_missing() {
    # appsettings.json is bind-mounted RW (write_compose_yml) so every Settings
    # UI write persists across `docker compose pull + up -d`. The image bakes
    # /app/appsettings.json with sensible defaults (telemetry endpoint,
    # Pantheon field-mapping placeholders, etc.); we extract those defaults
    # from the image on first install so the bind-mount target exists and
    # contains real defaults (an empty placeholder would make ASP.NET load `{}`
    # and lose every default value the image ships).
    local target="$INSTALL_DIR/appsettings.json"
    if [[ -f "$target" && -s "$target" ]]; then
        ok "appsettings.json preserved ($(wc -c <"$target") bytes -- customer settings kept)"
        return 0
    fi
    step "Seeding appsettings.json from image (first-run defaults)"
    if ! docker image inspect "$GHCR_IMAGE_BACKEND" &>/dev/null; then
        substep "Pulling $GHCR_IMAGE_BACKEND for defaults extraction (one-time)"
        docker pull "$GHCR_IMAGE_BACKEND" >/dev/null 2>&1 || \
            die "Could not pull $GHCR_IMAGE_BACKEND -- check Docker registry access."
    fi
    if ! docker run --rm --entrypoint cat "$GHCR_IMAGE_BACKEND" /app/appsettings.json > "$target" 2>/dev/null; then
        rm -f "$target"
        die "Could not extract /app/appsettings.json from $GHCR_IMAGE_BACKEND."
    fi
    chmod 644 "$target"
    ok "appsettings.json seeded ($(wc -c <"$target") bytes) -- Pantheon/SMTP/field-mappings now persist across upgrades."
}

fetch_cadbridge_zip() {
    # CadBridge agent ZIP is intentionally NOT baked into the gateway image
    # (would inflate the image by ~30 MB on every release for a workstation
    # artifact most server admins don't need to inspect). install.sh fetches
    # the latest version once at install time using the public manifest's
    # cadBridge.downloadUrl. After install, customers refresh via Apply
    # Update from the web UI.
    step "Fetching CadBridge installer ZIP"
    mkdir -p "$INSTALL_DIR/installers"

    local manifest cb_url
    manifest=$(curl -fsSL --max-time 10 \
        "${PUBLIC_REPO_BASE}/latest.json" 2>/dev/null) || {
        warn "Could not fetch manifest from $PUBLIC_REPO_BASE/latest.json"
        substep "Skipping CadBridge ZIP download. Workstation 'Download CadBridge' button"
        substep "will return 'CadBridge installer not built yet' until you drop the ZIP at"
        substep "${INSTALL_DIR}/installers/CadBridge-Setup.zip + sudo systemctl restart ${INSTALL_SLUG}."
        : > "$INSTALL_DIR/installers/CadBridge-Setup.zip"  # placeholder so bind-mount doesn't fail
        return 0
    }

    cb_url=$(echo "$manifest" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cadBridge',{}).get('downloadUrl',''))" 2>/dev/null)
    if [[ -z "$cb_url" ]]; then
        warn "Manifest has no cadBridge.downloadUrl; skipping CadBridge ZIP."
        : > "$INSTALL_DIR/installers/CadBridge-Setup.zip"
        return 0
    fi

    substep "Downloading $cb_url"
    if curl -fsSL --max-time 60 -o "$INSTALL_DIR/installers/CadBridge-Setup.zip" "$cb_url"; then
        local sz
        sz=$(stat -c%s "$INSTALL_DIR/installers/CadBridge-Setup.zip" 2>/dev/null || echo 0)
        ok "CadBridge ZIP downloaded ($((sz / 1024)) KB)"
    else
        warn "CadBridge ZIP download failed; will need manual scp."
        : > "$INSTALL_DIR/installers/CadBridge-Setup.zip"
    fi
}

install_helper_files() {
    [[ $INSTALL_HELPER -eq 1 ]] || return 0
    # Helper uses a single global socket path /run/3dx-gateway-helper.sock --
    # multiple parallel installs each running their own helper would race on
    # that path, last writer wins. Only install for the canonical slug; the
    # secondary install can still be operated manually
    # (`docker compose -p $INSTALL_SLUG ... up -d`) from the install dir.
    if [[ "$INSTALL_SLUG" != "3dx-gateway" ]]; then
        warn "Apply Update helper is global (single socket). Skipping for parallel install '${INSTALL_SLUG}'."
        substep "  -> Use: cd ${INSTALL_DIR} && docker compose -p ${INSTALL_SLUG} \$(cat compose.env|sed 's/COMPOSE_FILES=//;s/\"//g') pull && ... up -d"
        substep "  -> for one-click upgrades on this instance."
        return 0
    fi
    step "Installing Apply Update host helper"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    for f in 3dx-gateway-helper.sh 3dx-gateway-helper.socket 3dx-gateway-helper@.service install-helper.sh; do
        curl -fsSL "${PUBLIC_REPO_BASE}/scripts/host/$f" -o "$tmpdir/$f" || die "Failed to fetch $f from $PUBLIC_REPO_BASE"
    done
    chmod +x "$tmpdir"/*.sh
    COMPOSE_DIR="$INSTALL_DIR" bash "$tmpdir/install-helper.sh" >/dev/null
    ok "Helper installed (socket at /run/3dx-gateway-helper.sock)"
}

install_systemd_service() {
    step "Installing systemd service"
    write_compose_env
    ok "compose.env (COMPOSE_FILES=$(compute_compose_files))"
    write_systemd_unit
    systemctl enable "${INSTALL_SLUG}.service" >/dev/null
    ok "${INSTALL_SLUG}.service enabled at boot"
}

# Open the gateway's published ports in the host firewall (best-effort,
# non-fatal). Linux differs from Windows: Docker (engine) inserts its own
# iptables DOCKER-chain rules for published ports, which BYPASS ufw's filter
# chain, so ufw-published ports are usually already reachable and `ufw allow`
# is often a no-op (we still add it for hosts where it matters + to document
# intent). firewalld interacts with Docker more directly. We act only when a
# firewall is active and never stop on failure.
open_firewall() {
    if [[ $ARG_SKIP_FIREWALL -eq 1 ]]; then
        substep "Skipping firewall rules (--skip-firewall)."
        return 0
    fi
    local ports="$APP_PORT"
    if [[ "$TLS_MODE" != "none" && "$HTTP_PORT" != "0" ]]; then
        ports="$ports $HTTP_PORT"
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "Status: active"; then
        step "Opening firewall ports (ufw)"
        local p
        for p in $ports; do
            if ufw allow "${p}/tcp" >/dev/null 2>&1; then
                ok "ufw allow ${p}/tcp"
            else
                warn "ufw allow ${p}/tcp failed; add it by hand if LAN clients can't connect."
            fi
        done
        substep "Note: Docker publishes ports below ufw's filter chain, so they are usually reachable even without this rule."
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -qi running; then
        step "Opening firewall ports (firewalld)"
        local p
        for p in $ports; do
            if firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; then
                ok "firewalld add-port ${p}/tcp"
            else
                warn "firewalld add-port ${p}/tcp failed; add it by hand if LAN clients can't connect."
            fi
        done
        firewall-cmd --reload >/dev/null 2>&1 || warn "firewall-cmd --reload failed; run it manually."
    else
        substep "No active ufw/firewalld detected; relying on Docker's published ports (no firewall change)."
    fi
}

start_stack() {
    step "Pulling images + starting containers (~30-60 s)"
    cd "$INSTALL_DIR"
    # Explicit pull before first up: docker compose up -d uses the cached
    # image if one exists locally (no --pull always default), so a host that
    # had an older :latest cached from a prior install would silently keep
    # running the stale version. We want every install to land on the latest
    # GHCR :latest. Day-to-day systemd restarts (after this initial install)
    # use cache as intended.
    local compose_files
    compose_files=$(compute_compose_files)
    # shellcheck disable=SC2086
    docker compose -p "$INSTALL_SLUG" $compose_files pull --quiet || \
        warn "Image pull returned non-zero -- continuing with whatever is cached locally."
    systemctl start "${INSTALL_SLUG}.service"
    ok "Stack started"

    # Wait for app health (up to 90 s) by probing from the host (no docker
    # exec round-trip). Docker's own HEALTHCHECK is now real (curl is bundled
    # in the runtime image as of 2026-05-15) and the container reflects it,
    # but probing from the host stays cheaper for the install-time loop.
    #
    # Pre-increment `((++attempts))` is intentional: the post-increment form
    # returns the old value (0 first iteration) which trips set -e.
    local attempts=0
    local check_url
    check_url=$(build_check_url)
    while (( attempts < 30 )); do
        if curl -ksf --max-time 3 "$check_url" &>/dev/null; then
            ok "Backend healthcheck passed"
            return 0
        fi
        sleep 3
        ((++attempts))
    done
    warn "Backend didn't pass healthcheck within 90 s. Containers are up; check logs: \`docker logs ${INSTALL_SLUG}-app\`"
}

# Builds the URL used by wait-for-health + smoke_test. For HTTP we hit
# localhost (no Host header sensitivity, no DNS round-trip from the host
# itself). For HTTPS we use $HOSTNAME_FQDN because Caddy's `tls internal`
# cert is issued for exactly that name -- localhost wouldn't match and
# would return a useless name-mismatch from Caddy.
build_check_url() {
    if [[ "$TLS_MODE" == "none" ]]; then
        echo "http://localhost:${APP_PORT}/api/license/status"
    else
        echo "https://${HOSTNAME_FQDN}:${APP_PORT}/api/license/status"
    fi
}

smoke_test() {
    step "Smoke test"
    local url
    url=$(build_check_url)
    local resp
    if resp=$(curl -ksSL -w "\nHTTP_CODE:%{http_code}" --max-time 10 "$url" 2>&1); then
        local code
        code=$(echo "$resp" | grep "^HTTP_CODE:" | cut -d: -f2)
        local body
        body=$(echo "$resp" | grep -v "^HTTP_CODE:")
        if [[ "$code" == "200" ]]; then
            ok "$url returned 200"
            substep "$(echo "$body" | head -c 200)…"
        else
            warn "$url returned $code (probably DNS / certificate trust — check inside the LAN)"
        fi
    else
        warn "Could not reach $url from localhost (may be a hostname/DNS issue on the host itself; doesn't mean the LAN can't see it)"
    fi
}

# https://host/ for the standard 443; otherwise include the explicit port.
# Same shape for http on 80. Workstations need to type the URL exactly so
# omitting a non-standard port produces a connection refused on Caddy.
build_browser_url() {
    if [[ "$TLS_MODE" == "none" ]]; then
        if [[ "$APP_PORT" == "80" ]]; then
            echo "http://${HOSTNAME_FQDN}/"
        else
            echo "http://${HOSTNAME_FQDN}:${APP_PORT}/"
        fi
    else
        if [[ "$APP_PORT" == "443" ]]; then
            echo "https://${HOSTNAME_FQDN}/"
        else
            echo "https://${HOSTNAME_FQDN}:${APP_PORT}/"
        fi
    fi
}

print_summary() {
    hr
    cat <<EOF

${C_BOLD}${C_GREEN}✅ 3DX Gateway installed.${C_RESET}

  ${C_BOLD}Open in browser:${C_RESET}  $(build_browser_url)
  ${C_BOLD}Install dir:${C_RESET}      ${INSTALL_DIR}
  ${C_BOLD}Service:${C_RESET}          systemctl {status|restart|stop} ${INSTALL_SLUG}
  ${C_BOLD}Logs:${C_RESET}             docker logs -f ${INSTALL_SLUG}-app

EOF
    if [[ "$TLS_MODE" == "auto" ]]; then
        local ca_cmd
        if [[ "$HTTP_PORT" == "0" ]]; then
            ca_cmd="curl -k -O https://${HOSTNAME_FQDN}:${APP_PORT}/caddy-ca.crt"
        elif [[ "$HTTP_PORT" == "80" ]]; then
            ca_cmd="curl -O http://${HOSTNAME_FQDN}/caddy-ca.crt"
        else
            ca_cmd="curl -O http://${HOSTNAME_FQDN}:${HTTP_PORT}/caddy-ca.crt"
        fi
        cat <<EOF
  ${C_BOLD}TLS (local CA):${C_RESET}  Each workstation must install the Caddy CA once.
                    On the workstation, run as admin:
                      ${ca_cmd}
                      certutil -addstore -f Root caddy-ca.crt
                    CadBridge Setup.bat does this automatically.

EOF
    fi
    if [[ -z "$LICENSE_PATH" ]]; then
        cat <<EOF
  ${C_YELLOW}${C_BOLD}License pending:${C_RESET}
    The gateway is running but will refuse logins until license.lic is
    provided. When Solfins emails it, drop it in place and restart:
      sudo cp /path/to/license.lic ${INSTALL_DIR}/license.lic
      sudo systemctl restart ${INSTALL_SLUG}

EOF
    fi
    cat <<EOF
  ${C_BOLD}Next steps:${C_RESET}
    1. Open the URL above + log in with your 3DExperience credentials
    2. Settings → Pantheon credentials (if you use the ERP sync module)
    3. Distribute CadBridge to each workstation (link on the home page)

  ${C_BOLD}Customer install doc:${C_RESET}
    https://github.com/Solfins-dev/3dx-gateway-updates/blob/main/INSTALL.md

EOF
    hr
}

#─── Main ────────────────────────────────────────────────────────────────

confirm_summary() {
    [[ $ARG_YES -eq 1 ]] && return 0
    hr
    cat <<EOF

  ${C_BOLD}Ready to install:${C_RESET}
    install dir:  $INSTALL_DIR
    hostname:     $HOSTNAME_FQDN
    port (HTTPS): $APP_PORT
    $([[ "$TLS_MODE" != "none" ]] && echo "port (HTTP):  $([[ "$HTTP_PORT" == "0" ]] && echo "disabled (CA over HTTPS)" || echo "$HTTP_PORT (Caddy redirect + CA download)")")
    TLS:          $TLS_MODE
    license:      ${LICENSE_PATH:-"(pending -- add later from Solfins email)"}
    telemetry:    $TELEMETRY_ENABLED
    helper:       $([[ $INSTALL_HELPER -eq 1 ]] && echo install || echo skip)
EOF
    local yn
    yn=$(prompt_yn "Proceed?" "y")
    [[ "$yn" == "y" ]] || die "Cancelled."
}

main() {
    parse_args "$@"
    print_banner
    require_root
    check_os
    check_docker
    check_disk
    check_ram
    prompt_install_dir
    prompt_hostname
    prompt_tls_mode
    prompt_port
    resolve_http_port
    detect_existing_install
    prompt_license
    prompt_telemetry
    prompt_helper
    confirm_summary

    if [[ $ARG_DRY_RUN -eq 1 ]]; then
        step "DRY RUN — would write files + install systemd + pull images. Exiting."
        exit 0
    fi

    generate_secrets
    write_files
    install_helper_files
    install_systemd_service
    start_stack
    open_firewall
    smoke_test
    print_summary
}

main "$@"
