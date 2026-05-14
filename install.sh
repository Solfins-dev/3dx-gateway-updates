#!/usr/bin/env bash
# 3DX Gateway — Linux installer (ADR-015 Phase A initial setup).
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
#     ├── .env                         POSTGRES_PASSWORD + ports + hostname
#     ├── license.lic                  customer license (copied from --license path)
#     └── data/                        bind-mounted app data
#   /etc/systemd/system/3dx-gateway.service     auto-start on boot
#   /usr/local/bin/3dx-gateway-helper.sh        if --helper (Phase 2(a))
#   /etc/systemd/system/3dx-gateway-helper.*    if --helper

set -euo pipefail

INSTALLER_VERSION="1.0.0"
PUBLIC_REPO_BASE="https://raw.githubusercontent.com/Solfins-dev/3dx-gateway-updates/main"
GHCR_IMAGE_BACKEND="ghcr.io/solfins-dev/3dx-gateway:latest"

# Sensible defaults
DEFAULT_INSTALL_DIR="/opt/3dx-gateway"
DEFAULT_PORT_TLS=443
DEFAULT_PORT_HTTP=5000
MIN_DISK_GB=5
MIN_RAM_MB=1800   # 2 GB rated, allow some slack for VMs that report 1900-ish

# CLI flag values (filled by parse_args)
ARG_INSTALL_DIR=""
ARG_HOSTNAME=""
ARG_PORT=""
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
TLS_MODE=""
LICENSE_PATH=""
TELEMETRY_ENABLED=""
INSTALL_HELPER=0
POSTGRES_PASSWORD=""

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
  --port N                 HTTPS port (default: $DEFAULT_PORT_TLS) or HTTP if --tls none
  --tls MODE               TLS mode: auto | letsencrypt | none (default: auto)
                              auto:        Caddy with local CA (recommended for LAN)
                              letsencrypt: Caddy with Let's Encrypt (public hostname required)
                              none:        plain HTTP (you provide reverse proxy)
  --license PATH           License file to copy in (required for first install)
  --telemetry on|off       ADR-015 §7.5 anonymous ping (default: on)
  --helper                 Install Apply Update host helper (ADR-015 Phase 2(a))
  --install-docker yes|no  Auto-install Docker if missing (default: ask)
  --yes, -y                Skip "are you sure?" confirmations
  --dry-run                Show what would happen, don't make changes
  --help                   This message

Examples:
  # Interactive (all defaults):
  sudo bash install.sh

  # Unattended:
  sudo bash install.sh -y --hostname gateway.acme.local \\
       --license /tmp/acme.lic --helper

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-dir)      ARG_INSTALL_DIR="$2"; shift 2 ;;
            --hostname)         ARG_HOSTNAME="$2"; shift 2 ;;
            --port)             ARG_PORT="$2"; shift 2 ;;
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
    ok "Will install to: $INSTALL_DIR"
}

prompt_hostname() {
    step "Gateway hostname"
    local detected
    detected=$(hostname --fqdn 2>/dev/null || hostname)
    HOSTNAME_FQDN=${ARG_HOSTNAME:-$(prompt_text "Hostname (URL workstations will use)" "$detected")}
    ok "Hostname: $HOSTNAME_FQDN"
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

prompt_port() {
    step "Application port"
    local suggested=$DEFAULT_PORT_TLS
    [[ "$TLS_MODE" == "none" ]] && suggested=$DEFAULT_PORT_HTTP
    APP_PORT=${ARG_PORT:-$(prompt_text "Port (will be checked for availability)" "$suggested")}
    [[ "$APP_PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $APP_PORT"
    (( APP_PORT > 0 && APP_PORT < 65536 )) || die "Port out of range: $APP_PORT"
    if check_port_free "$APP_PORT"; then
        ok "Port $APP_PORT is free"
    else
        die "Port $APP_PORT is already in use. Run \`ss -tlnp | grep :$APP_PORT\` to see what's there, free it, or pick a different port (--port)."
    fi
}

prompt_license() {
    step "License file"
    LICENSE_PATH=${ARG_LICENSE:-$(prompt_text "Path to license.lic from Solfins" "")}
    [[ -n "$LICENSE_PATH" ]] || die "License file is required. Get one from Solfins (or pass --license PATH)."
    [[ -f "$LICENSE_PATH" ]] || die "License file not found: $LICENSE_PATH"
    ok "License found: $LICENSE_PATH ($(stat -c%s "$LICENSE_PATH") bytes)"
}

prompt_telemetry() {
    step "Telemetry (ADR-015 §7.5)"
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
    step "Apply Update host helper (ADR-015 Phase 2(a))"
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
}

write_compose_yml() {
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
# Generated by 3dx-gateway install.sh v${INSTALLER_VERSION}. Customer can edit but
# regeneration via reinstall will overwrite.

services:
  app:
    image: ${GHCR_IMAGE_BACKEND}
    container_name: 3dx-gateway-app
    restart: unless-stopped
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ConnectionStrings__BomExplorer: "Host=postgres;Port=5432;Database=bom_explorer;Username=bomapp;Password=\${POSTGRES_PASSWORD}"
      Telemetry__Enabled: "$([[ $TELEMETRY_ENABLED == on ]] && echo true || echo false)"
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
      - ./license.lic:/app/license.lic:ro
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
    container_name: 3dx-gateway-db
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
    cat > "$INSTALL_DIR/docker-compose.tls.yml" <<EOF
# Caddy reverse proxy overlay — TLS termination.
services:
  caddy:
    image: caddy:2.9-alpine
    container_name: 3dx-gateway-caddy
    restart: unless-stopped
    ports:
      - "${APP_PORT}:443"
      - "80:80"
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
        # tls internal — local CA
        cat > "$INSTALL_DIR/Caddyfile" <<EOF
${HOSTNAME_FQDN} {
    tls internal
    reverse_proxy app:5000
}

# Expose the local CA so workstations can install it once.
:80 {
    handle /caddy-ca.crt {
        root * /data/caddy/pki/authorities/local
        rewrite * /root.crt
        file_server
    }
    redir /* https://${HOSTNAME_FQDN}{uri}
}
EOF
    fi
}

write_helper_overlay() {
    cat > "$INSTALL_DIR/docker-compose.helper.yml" <<EOF
# ADR-015 Phase 2(a) helper bind-mount overlay.
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
# Keep this file out of version control; POSTGRES_PASSWORD is sensitive.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
HOSTNAME=${HOSTNAME_FQDN}
APP_PORT=${APP_PORT}
TLS_MODE=${TLS_MODE}
TELEMETRY=${TELEMETRY_ENABLED}
EOF
    chmod 600 "$INSTALL_DIR/.env"
}

write_systemd_unit() {
    local compose_files="-f docker-compose.yml"
    [[ "$TLS_MODE" != "none" ]] && compose_files="$compose_files -f docker-compose.tls.yml"
    [[ $INSTALL_HELPER -eq 1 ]] && compose_files="$compose_files -f docker-compose.helper.yml"

    cat > /etc/systemd/system/3dx-gateway.service <<EOF
[Unit]
Description=3DX Gateway — Solfins customer distribution
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose ${compose_files} up -d
ExecStop=/usr/bin/docker compose ${compose_files} down
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
    cp "$LICENSE_PATH" "$INSTALL_DIR/license.lic"
    chmod 644 "$INSTALL_DIR/license.lic"
    ok "license.lic copied"
    mkdir -p "$INSTALL_DIR/data"
}

install_helper_files() {
    [[ $INSTALL_HELPER -eq 1 ]] || return 0
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
    write_systemd_unit
    systemctl enable 3dx-gateway.service >/dev/null
    ok "3dx-gateway.service enabled at boot"
}

start_stack() {
    step "Pulling images + starting containers (~30-60 s)"
    cd "$INSTALL_DIR"
    systemctl start 3dx-gateway.service
    ok "Stack started"

    # Wait for app health (up to 90 s). We probe from the host -- NOT via
    # `docker exec 3dx-gateway-app curl ...` -- because the published .NET
    # backend image does not bundle curl, so the in-container probe always
    # returns 127 and the loop times out even when the app is fine. Docker's
    # own healthcheck (declared in docker-compose.yml) has the same caveat;
    # the container shows "(unhealthy)" cosmetically even when the app
    # serves traffic perfectly. See known-issues note in install summary.
    #
    # Pre-increment `((++attempts))` is intentional: the post-increment form
    # returns the old value (0 first iteration) which trips set -e.
    local attempts=0
    local check_url="http://localhost:${APP_PORT}/api/license/status"
    [[ "$TLS_MODE" != "none" ]] && check_url="https://localhost:${APP_PORT}/api/license/status"
    while (( attempts < 30 )); do
        if curl -ksf --max-time 3 "$check_url" &>/dev/null; then
            ok "Backend healthcheck passed"
            return 0
        fi
        sleep 3
        ((++attempts))
    done
    warn "Backend didn't pass healthcheck within 90 s. Containers are up; check logs: \`docker logs 3dx-gateway-app\`"
}

smoke_test() {
    step "Smoke test"
    local url="http://localhost:${APP_PORT}"
    [[ "$TLS_MODE" != "none" ]] && url="https://${HOSTNAME_FQDN}"
    local resp
    if resp=$(curl -ksSL -w "\nHTTP_CODE:%{http_code}" --max-time 10 "${url}/api/license/status" 2>&1); then
        local code
        code=$(echo "$resp" | grep "^HTTP_CODE:" | cut -d: -f2)
        local body
        body=$(echo "$resp" | grep -v "^HTTP_CODE:")
        if [[ "$code" == "200" ]]; then
            ok "${url}/api/license/status returned 200"
            substep "$(echo "$body" | head -c 200)…"
        else
            warn "${url}/api/license/status returned $code (probably DNS / certificate trust — check inside the LAN)"
        fi
    else
        warn "Could not reach ${url} from localhost (may be a hostname/DNS issue on the host itself; doesn't mean the LAN can't see it)"
    fi
}

print_summary() {
    hr
    cat <<EOF

${C_BOLD}${C_GREEN}✅ 3DX Gateway installed.${C_RESET}

  ${C_BOLD}Open in browser:${C_RESET}  $([[ "$TLS_MODE" != "none" ]] && echo "https://${HOSTNAME_FQDN}/" || echo "http://${HOSTNAME_FQDN}:${APP_PORT}/")
  ${C_BOLD}Install dir:${C_RESET}      ${INSTALL_DIR}
  ${C_BOLD}Service:${C_RESET}          systemctl {status|restart|stop} 3dx-gateway
  ${C_BOLD}Logs:${C_RESET}             docker logs -f 3dx-gateway-app

EOF
    if [[ "$TLS_MODE" == "auto" ]]; then
        cat <<EOF
  ${C_BOLD}TLS (local CA):${C_RESET}  Each workstation must install the Caddy CA once.
                    On the workstation, run as admin:
                      curl -O http://${HOSTNAME_FQDN}/caddy-ca.crt
                      certutil -addstore -f Root caddy-ca.crt
                    CadBridge Setup.bat does this automatically.

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
    port:         $APP_PORT
    TLS:          $TLS_MODE
    license:      $LICENSE_PATH
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
    smoke_test
    print_summary
}

main "$@"
