#!/usr/bin/env bash
# 3DX Gateway host updater (Apply Update helper).
#
# Reads ONE command line from stdin (Unix socket connection from systemd
# socket-activation), writes ONE JSON response to stdout, exits. systemd
# spawns one instance per connection (Accept=yes).
#
# Protocol (plain-text, line-oriented for trivial parsing):
#   PING\n      -> {"ok":true,"helperVersion":"1.0.0"}
#   STATUS\n    -> contents of $STATUS_FILE, or {"stage":"idle"} if absent
#   APPLY\n     -> kicks off `docker compose pull && up -d` in the background,
#                  returns {"started":true} immediately
#
# Status file is written by the background apply job at each stage:
#   {"stage":"pulling","startedAt":"<iso8601>"}
#   {"stage":"restarting","startedAt":"<iso8601>"}
#   {"stage":"done","finishedAt":"<iso8601>"}
#   {"stage":"error","finishedAt":"<iso8601>","error":"<msg>","logPath":"<path>"}
#
# The gateway container polls STATUS to know when to reload. After "done", the
# container has been recreated and will be reachable on a new TCP connection;
# the previous backend instance has already exited, so the apply-status poll
# transitions through "connection refused" briefly while Docker swaps the
# containers.

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/3dx-gateway}"
# COMPOSE_FILES wins over COMPOSE_FILE — accepts a space-separated list so
# dev01 (and other multi-overlay deployments) can layer staging + helper
# overlays in the apply path. Customer prod installs typically set just
# COMPOSE_FILE=docker-compose.prod.yml.
COMPOSE_FILES_RAW="${COMPOSE_FILES:-${COMPOSE_FILE:-docker-compose.prod.yml}}"
# shellcheck disable=SC2206  # word-splitting is intentional here
COMPOSE_FILES_ARR=($COMPOSE_FILES_RAW)
# Build the `-f <file>` flag list once so the worker bash can interpolate
# without re-splitting.
COMPOSE_FLAGS=""
for f in "${COMPOSE_FILES_ARR[@]}"; do
    COMPOSE_FLAGS="$COMPOSE_FLAGS -f $f"
done
STATE_DIR="${STATE_DIR:-/var/lib/3dx-gateway-helper}"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/last-apply.log"
HELPER_VERSION="1.0.0"

mkdir -p "$STATE_DIR"

# Read one line, strip trailing CR (curl with --unix-socket may add it).
IFS= read -r raw_cmd || raw_cmd=""
cmd="${raw_cmd%$'\r'}"

write_status() {
    # Atomic write so STATUS reads never see a half-written file.
    local content="$1"
    local tmp
    tmp="$(mktemp -p "$STATE_DIR" .status.XXXXXX)"
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$STATUS_FILE"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# JSON value-escape: only handles strings that may contain backslash or
# double-quote. Sufficient for our timestamps + error messages.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

case "$cmd" in
    PING)
        printf '{"ok":true,"helperVersion":"%s"}\n' "$HELPER_VERSION"
        ;;

    STATUS)
        if [[ -f "$STATUS_FILE" ]]; then
            cat "$STATUS_FILE"
        else
            printf '{"stage":"idle"}\n'
        fi
        ;;

    APPLY)
        # Mark the apply as in-flight BEFORE forking the background job so
        # a fast STATUS poll right after APPLY sees "pulling", not "idle".
        write_status "$(printf '{"stage":"pulling","startedAt":"%s"}' "$(now_iso)")"

        # Async background job. Fully detached so this process can return
        # the {"started":true} response and exit promptly. setsid + nohup
        # gives us a session of our own so systemd won't kill the worker
        # when our handler process exits.
        setsid nohup bash -c '
            set -o pipefail
            apply_log="'"$LOG_FILE"'"
            status_file="'"$STATUS_FILE"'"
            compose_dir="'"$COMPOSE_DIR"'"
            compose_flags="'"$COMPOSE_FLAGS"'"

            : > "$apply_log"
            cd "$compose_dir" 2>>"$apply_log" || {
                printf "{\"stage\":\"error\",\"finishedAt\":\"%s\",\"error\":\"cannot cd to %s\",\"logPath\":\"%s\"}\n" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$compose_dir" "$apply_log" > "$status_file"
                exit 1
            }

            # compose_flags is intentionally unquoted — it expands to multiple
            # -f arguments. Word-splitting is the goal here.
            # shellcheck disable=SC2086
            if ! docker compose $compose_flags pull 2>>"$apply_log" >>"$apply_log"; then
                printf "{\"stage\":\"error\",\"finishedAt\":\"%s\",\"error\":\"docker compose pull failed\",\"logPath\":\"%s\"}\n" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$apply_log" > "$status_file"
                exit 1
            fi

            printf "{\"stage\":\"restarting\",\"startedAt\":\"%s\"}\n" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"

            # shellcheck disable=SC2086
            if ! docker compose $compose_flags up -d 2>>"$apply_log" >>"$apply_log"; then
                printf "{\"stage\":\"error\",\"finishedAt\":\"%s\",\"error\":\"docker compose up failed\",\"logPath\":\"%s\"}\n" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$apply_log" > "$status_file"
                exit 1
            fi

            printf "{\"stage\":\"done\",\"finishedAt\":\"%s\"}\n" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$status_file"
        ' </dev/null >/dev/null 2>&1 &
        disown || true

        printf '{"started":true,"at":"%s"}\n' "$(now_iso)"
        ;;

    "")
        printf '{"error":"empty command"}\n'
        ;;

    *)
        escaped_cmd="$(json_escape "$cmd")"
        printf '{"error":"unknown command","received":"%s"}\n' "$escaped_cmd"
        ;;
esac
