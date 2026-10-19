#!/usr/bin/env bash
# ===========================================================================
#  Nextcloud on Podman — local-network setup, no domain, no public exposure.
#
#  Usage:  ./setup.sh [command]
#
#    up          (default) create .env if missing, build the Caddy image and the
#                TLS certificate if needed, install the systemd user units,
#                remove leftover non-Quadlet containers, migrate file ownership
#                to your user, start the services, wait for the web UI to
#                answer, then print the access URLs
#    install     create the data dir and TLS certificate and (re)generate the
#                systemd user units and env files; starts nothing
#    down        stop the services (volumes and data are kept)
#    restart     re-render the units and restart to pick up .env / unit edits
#    status      show unit and container state, ports, volumes and ownership
#    logs [svc]  follow logs (all services via journald, or one of:
#                app db redis cron caddy)
#    occ ...     run an occ command inside the running app container, as its
#                web account (interactive prompts work)
#                e.g.  ./setup.sh occ user:add alice
#    creds       print the generated administrator password
#    backup [--quiesce]
#                write a database dump plus data/config tarballs; with
#                --quiesce Nextcloud is in maintenance mode meanwhile, so the
#                database and the files are captured in the same state
#    restore [d] replace the current instance with a backup (default: newest
#                complete one): verifies the archives, empties the data dir,
#                recreates the html/db/redis volumes, restores files, database
#                and config.php  (type RESTORE)
#    uninstall   stop the services and remove the systemd units and generated
#                env files; volumes, data, .env and tls/ are kept
#    destroy     remove containers, network AND every named volume (type
#                DELETE); the host data directory is never deleted
#    help        this text
#
#  Every service runs as a `systemctl --user` unit (Podman Quadlet) and as YOUR
#  user, so every file the stack writes is yours and files shared over SMB stay
#  writable. (Only cron's `crond` supervisor is container-root, i.e. a host
#  sub-uid; it writes nothing and its jobs run as you.)
#  Everything is idempotent: running `up` twice does not create a second stack
#  and never regenerates secrets that already exist in .env.
# ===========================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Resolve the script's own directory so it can be run from anywhere.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR

# These three can be redirected (tests render into throw-away directories without
# touching the live stack); the defaults are what a normal run uses.
readonly ENV_FILE="${NEXTCLOUD_ENV_FILE:-.env}"
readonly ENV_EXAMPLE=".env.example"

# systemd user units (Podman Quadlet). The templates in systemd/*.in are
# rendered into QUADLET_DIR, where Podman's systemd generator turns them into
# nextcloud-<service>.service. Per-service env files (they hold secrets) are
# written to RUN_DIR, which is mode 0700 and git-ignored.
readonly UNIT_SRC_DIR="systemd"
readonly RUN_DIR="${NEXTCLOUD_RUN_DIR:-.run}"
readonly QUADLET_DIR="${NEXTCLOUD_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
readonly SERVICES=(db redis app cron caddy)       # start order
readonly NETWORK_NAME="nextcloud-net"

# Image defaults. Each one can be overridden in .env (NEXTCLOUD_IMAGE, DB_IMAGE,
# REDIS_IMAGE, CADDY_IMAGE) and is read through image_of(), so `app` and `cron`
# always take the SAME value and can never drift to different versions. Never
# edit the rendered units.
readonly DEFAULT_NEXTCLOUD_IMAGE="docker.io/library/nextcloud:35-apache"
readonly DEFAULT_DB_IMAGE="docker.io/library/mariadb:11"
readonly DEFAULT_REDIS_IMAGE="docker.io/library/redis:7-alpine"
readonly DEFAULT_CADDY_IMAGE="localhost/nextcloud-caddy-brotli:2"   # built from docker/caddy

# Accounts the upstream images run their service as. The NAMES are the images'
# documented contract (override in .env if an image changes them); the numeric
# UIDs/GIDs are never assumed — they are read from the image (see service_ids).
readonly DEFAULT_APP_RUN_USER="www-data"
readonly DEFAULT_DB_RUN_USER="mysql"
readonly DEFAULT_REDIS_RUN_USER="redis"

readonly APP_CONTAINER="nextcloud-app"
readonly DB_CONTAINER="nextcloud-db"

# Explicit volume names, matching the `Volume=` lines in systemd/*.in. The user
# data lives in a host directory (DATA_HOST_PATH), not in a named volume.
readonly VOL_HTML="nextcloud-html"
readonly VOL_CADDY="nextcloud-caddy-data"
readonly VOL_DB="nextcloud-db"
readonly VOL_REDIS="nextcloud-redis"

# Small image used to move files in and out of volumes. The Nextcloud image
# would work too, but this one is a few megabytes instead of a gigabyte.
readonly DEFAULT_HELPER_IMAGE="docker.io/library/alpine:3"   # override: HELPER_IMAGE in .env

# Defaults for the published ports and bind address. Every value is overridable
# in .env (NEXTCLOUD_PORT, NEXTCLOUD_HTTPS_PORT, NEXTCLOUD_BIND); they live here
# once so no call site repeats a literal.
readonly DEFAULT_HTTP_PORT="8080"
readonly DEFAULT_HTTPS_PORT="52443"
readonly DEFAULT_BIND="0.0.0.0"

# Seconds to wait for the web interface before giving up.
readonly STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"

# Where the user ran us from (relative arguments, e.g. `restore ./my-backup`).
INVOKE_DIR="$PWD"
readonly INVOKE_DIR
# This script's own path, valid after the `cd` below (used by `help`).
readonly SELF="$PROJECT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

cd -- "$PROJECT_DIR"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

step()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

require_cmd() {
    command -v -- "$1" >/dev/null 2>&1 || die "'$1' is not installed or not on PATH."
}

# Print a 48-character hex password. Hex only, on purpose: no shell quoting
# hazards, no characters that a dotenv parser might eat.
gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        LC_ALL=C od -An -tx1 -N24 /dev/urandom | tr -d ' \n'
        printf '\n'
    fi
}

# The address other LAN machines will use, i.e. the source address of the route
# towards the outside world. Falls back to the first non-loopback IPv4.
detect_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
        if [ -z "$ip" ]; then
            ip="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR == 1 {split($4, a, "/"); print a[1]}')"
        fi
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "$ip"
}

detect_timezone() {
    local tz=""
    if [ -n "${TZ:-}" ]; then
        tz="$TZ"
    elif [ -r /etc/timezone ]; then
        tz="$(head -1 /etc/timezone)"
    elif command -v timedatectl >/dev/null 2>&1; then
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    elif [ -L /etc/localtime ]; then
        tz="$(readlink -f /etc/localtime | sed -n 's#.*/zoneinfo/##p')"
    fi
    [ -n "$tz" ] || tz="UTC"
    printf '%s' "$tz"
}

# Read a single key out of .env without executing it.
env_get() {
    local key="$1"
    [ -r "$ENV_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}

# ---------------------------------------------------------------------------
# Container engine wrappers
# ---------------------------------------------------------------------------

sctl() { systemctl --user "$@"; }

unit_of() { printf 'nextcloud-%s.service' "$1"; }

# Value of KEY from .env, or DEFAULT when unset/empty.
env_or() {
    local v
    v="$(env_get "$1")"
    printf '%s' "${v:-$2}"
}

# Fail early (and helpfully) when a required key is missing from .env.
env_need() {
    local v
    v="$(env_get "$1")"
    [ -n "$v" ] || die "$1 is not set in $ENV_FILE."
    printf '%s' "$v"
}

# Host directory that holds the Nextcloud user data (shared e.g. over SMB).
data_path() {
    local d
    d="$(env_or DATA_HOST_PATH "$PROJECT_DIR/data")"
    # A relative path would be taken by Podman for a NAMED VOLUME.
    case "$d" in
        /*) ;;
        *)  die "DATA_HOST_PATH must be an absolute path (got '$d')." ;;
    esac
    printf '%s' "$d"
}

# The web account inside the Nextcloud image (what `occ` must run as).
app_user() { env_or APP_RUN_USER "$DEFAULT_APP_RUN_USER"; }

# Address to probe the published ports on: the bind address, or loopback when
# bound to every interface.
probe_host() {
    local b
    b="$(env_or NEXTCLOUD_BIND "$DEFAULT_BIND")"
    case "$b" in
        0.0.0.0|""|"::"|"[::]") printf '127.0.0.1' ;;
        *)                      printf '%s' "$b" ;;
    esac
}

# The invoking host user. `$USER` is not set in every context (cron, systemd),
# so ask the system instead.
me_user() { id -un; }
me_uid()  { id -u; }
me_gid()  { id -g; }

# Effective image reference: .env override, else the default above.
image_of() {
    case "$1" in
        nextcloud) env_or NEXTCLOUD_IMAGE "$DEFAULT_NEXTCLOUD_IMAGE" ;;
        db)        env_or DB_IMAGE        "$DEFAULT_DB_IMAGE" ;;
        redis)     env_or REDIS_IMAGE     "$DEFAULT_REDIS_IMAGE" ;;
        caddy)     env_or CADDY_IMAGE     "$DEFAULT_CADDY_IMAGE" ;;
        helper)    env_or HELPER_IMAGE    "$DEFAULT_HELPER_IMAGE" ;;
        *)         die "image_of: unknown image '$1'" ;;
    esac
}

# uid and gid of ACCOUNT inside IMAGE, read from the image itself so nothing
# about the image's internals is assumed. Output: "<uid> <gid>".
image_account_ids() {
    local image="$1" account="$2" out
    out="$(podman run --rm --pull=never --entrypoint sh "$image" -c \
            "printf '%s %s' \"\$(id -u '$account')\" \"\$(id -g '$account')\"" 2>/dev/null)" \
        || return 1
    [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] || return 1
    printf '%s' "$out"
}

# Resolve the identity a service runs as. Precedence: .env override
# (<PREFIX>_UID / <PREFIX>_GID / <PREFIX>_RUN_USER), else discovered from the
# image. Sets the globals <PREFIX>_RUN_USER, <PREFIX>_UID and <PREFIX>_GID.
#   service_ids APP nextcloud
service_ids() {
    local prefix="$1" image_key="$2" default_user ids user uid gid image
    case "$prefix" in
        APP)   default_user="$DEFAULT_APP_RUN_USER" ;;
        DB)    default_user="$DEFAULT_DB_RUN_USER" ;;
        REDIS) default_user="$DEFAULT_REDIS_RUN_USER" ;;
        *)     die "service_ids: unknown prefix '$prefix'" ;;
    esac
    user="$(env_or "${prefix}_RUN_USER" "$default_user")"
    uid="$(env_get "${prefix}_UID")"
    gid="$(env_get "${prefix}_GID")"
    if [ -z "$uid" ] || [ -z "$gid" ]; then
        image="$(image_of "$image_key")"
        podman image exists "$image" 2>/dev/null || podman pull -q "$image" >/dev/null \
            || die "cannot pull $image to read its '$user' account."
        ids="$(image_account_ids "$image" "$user")" \
            || die "image $image has no account '$user'. Set ${prefix}_RUN_USER (or ${prefix}_UID and ${prefix}_GID) in $ENV_FILE."
        uid="${uid:-${ids% *}}"
        gid="${gid:-${ids#* }}"
    fi
    printf -v "${prefix}_RUN_USER" '%s' "$user"
    printf -v "${prefix}_UID" '%s' "$uid"
    printf -v "${prefix}_GID" '%s' "$gid"
}

# Subnet(s) of the stack's private bridge, as Podman actually allocated them.
# These are the only peers whose X-Forwarded-* headers Nextcloud may trust.
network_subnets() {
    local out
    out="$(podman network inspect "$NETWORK_NAME" -f '{{range .Subnets}}{{.Subnet}} {{end}}' 2>/dev/null)" || return 0
    printf '%s' "${out% }"
}

# Make sure the Quadlet-managed network really exists (so its subnet can be
# read). The network unit is a one-shot that stays "active" after it ran, so a
# network removed behind systemd's back (podman network rm) is not recreated by
# a plain `start` — restart the unit when the network itself is missing.
ensure_network() {
    if ! podman network exists "$NETWORK_NAME" 2>/dev/null; then
        sctl restart nextcloud-network.service \
            || die "could not create the $NETWORK_NAME network (journalctl --user -u nextcloud-network)."
        podman network exists "$NETWORK_NAME" 2>/dev/null \
            || die "the $NETWORK_NAME network is still missing after starting nextcloud-network.service."
    fi
}

require_systemd() {
    require_cmd podman
    require_cmd systemctl
    [ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    sctl show-environment >/dev/null 2>&1 \
        || die "cannot reach 'systemd --user'. Log in as $(me_user) on this host (or run: loginctl enable-linger $(me_user))."
    QUADLET_BIN=""
    local c
    for c in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do
        [ -x "$c" ] && { QUADLET_BIN="$c"; break; }
    done
    [ -n "$QUADLET_BIN" ] || die "Podman's Quadlet generator was not found; Podman >= 4.4 is required."
}

# Keep the services running after logout and bring them up at boot.
ensure_linger() {
    if [ "$(loginctl show-user "$(me_user)" -p Linger --value 2>/dev/null)" = "yes" ]; then
        ok "linger enabled for $(me_user) (services start at boot)"
    elif loginctl enable-linger "$(me_user)" 2>/dev/null; then
        ok "enabled linger for $(me_user) (services start at boot)"
    else
        warn "could not enable linger; run once as root: loginctl enable-linger $(me_user)"
    fi
}

# ---------------------------------------------------------------------------
# .env bootstrap
# ---------------------------------------------------------------------------

ensure_env() {
    if [ -f "$ENV_FILE" ]; then
        ok "$ENV_FILE already exists — leaving it untouched"
        return 0
    fi

    [ -f "$ENV_EXAMPLE" ] || die "$ENV_EXAMPLE is missing; cannot generate $ENV_FILE."

    step "Generating $ENV_FILE with fresh secrets"

    local lan_ip host tz admin_user db_pass db_root admin_pass trusted
    lan_ip="$(detect_lan_ip)"
    host="$(hostname 2>/dev/null || echo nextcloud)"
    tz="$(detect_timezone)"
    admin_user="admin"
    db_pass="$(gen_secret)"
    db_root="$(gen_secret)"
    admin_pass="$(gen_secret)"

    # Nextcloud refuses to answer for host names it has not been told about.
    trusted="localhost 127.0.0.1 ${host}"
    [ -n "$lan_ip" ] && trusted="${trusted} ${lan_ip}"

    # Subshell: the restrictive umask must not leak into the rest of the run
    # (it would make the data directory, tls/ and the units 0700/0600).
    (
        umask 077
        sed \
            -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(sed_esc "$db_pass")|" \
            -e "s|^DB_ROOT_PASSWORD=.*|DB_ROOT_PASSWORD=$(sed_esc "$db_root")|" \
            -e "s|^NEXTCLOUD_ADMIN_USER=.*|NEXTCLOUD_ADMIN_USER=$(sed_esc "$admin_user")|" \
            -e "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=$(sed_esc "$admin_pass")|" \
            -e "s|^NEXTCLOUD_TRUSTED_DOMAINS=.*|NEXTCLOUD_TRUSTED_DOMAINS=$(sed_esc "$trusted")|" \
            -e "s|^NEXTCLOUD_OVERWRITE_CLI_URL=.*|NEXTCLOUD_OVERWRITE_CLI_URL=http://$(sed_esc "$host"):${DEFAULT_HTTP_PORT}|" \
            -e "s|^DATA_HOST_PATH=.*|DATA_HOST_PATH=$(sed_esc "$PROJECT_DIR")/data|" \
            -e "s|^TZ=.*|TZ=$(sed_esc "$tz")|" \
            "$ENV_EXAMPLE" > "$ENV_FILE"
    )

    chmod 0600 "$ENV_FILE"
    ok "wrote $ENV_FILE (mode 0600)"
}

# ---------------------------------------------------------------------------
# TLS certificate for the Caddy front end
# ---------------------------------------------------------------------------

TLS_DIR="tls"

# Self-signed certificate for ./Caddyfile. Idempotent: it is only regenerated
# when missing or when it no longer covers a host name / IP we would be
# reached by (e.g. the LAN address changed). Names come from
# NEXTCLOUD_TRUSTED_DOMAINS plus the detected LAN IP and host name, so the
# certificate and Nextcloud's trusted domains cannot drift apart.
ensure_tls() {
    require_cmd openssl

    local host lan_ip name want=() san="" have
    host="$(hostname 2>/dev/null || echo nextcloud)"
    lan_ip="$(detect_lan_ip)"

    for name in localhost 127.0.0.1 "$host" "${host}.local" "$lan_ip" \
                $(env_get NEXTCLOUD_TRUSTED_DOMAINS); do
        [ -n "$name" ] || continue
        # Nextcloud allows "host:port" in trusted domains; a certificate name
        # never carries a port. (Two or more colons = an IPv6 literal: keep.)
        if [[ "$name" =~ ^[^:]+:[0-9]+$ ]]; then name="${name%:*}"; fi
        # De-duplicate while keeping order.
        case " ${want[*]:-} " in *" $name "*) continue ;; esac
        want+=("$name")
    done

    for name in "${want[@]}"; do
        # Anything that looks like an IPv4/IPv6 literal is an IP SAN, the rest DNS.
        if [[ "$name" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || [[ "$name" == *:* ]]; then
            san="${san:+$san,}IP:${name}"
        else
            san="${san:+$san,}DNS:${name}"
        fi
    done

    if [ -r "$TLS_DIR/site.crt" ] && [ -r "$TLS_DIR/site.key" ] \
        && openssl x509 -checkend 2592000 -noout -in "$TLS_DIR/site.crt" >/dev/null 2>&1; then
        # One SAN per line, so matching is exact (192.168.1.5 must not be
        # satisfied by a certificate that only has 192.168.1.50).
        have="$(openssl x509 -noout -ext subjectAltName -in "$TLS_DIR/site.crt" 2>/dev/null \
                | tr ',' '\n' | sed 's/^[[:space:]]*//')"
        local missing=0 token
        for token in ${san//,/ }; do
            # openssl prints IP SANs as "IP Address:x".
            grep -qxF -- "${token/IP:/IP Address:}" <<<"$have" || missing=1
        done
        if [ "$missing" -eq 0 ]; then
            ok "TLS certificate in $TLS_DIR/ is valid and covers all names"
            return 0
        fi
        warn "TLS certificate does not cover every current name/IP — regenerating"
    fi

    step "Generating self-signed TLS certificate ($TLS_DIR/site.crt)"
    mkdir -p "$TLS_DIR"
    ( umask 077
      openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
          -subj "/CN=${host}" -addext "subjectAltName=${san}" \
          -keyout "$TLS_DIR/site.key" -out "$TLS_DIR/site.crt" >/dev/null 2>&1 ) \
        || die "openssl failed to generate the TLS certificate."
    # The Caddy container runs as the mapped host user; keep the key private
    # but make the pair readable for that mapping.
    chmod 0644 "$TLS_DIR/site.crt"; chmod 0600 "$TLS_DIR/site.key"
    ok "valid for: ${san//,/, }"
}

# ---------------------------------------------------------------------------
# Caddy image
# ---------------------------------------------------------------------------

# The Caddyfile uses `encode zstd br gzip`; Brotli is not in stock Caddy, so the
# image is built once from docker/caddy/Containerfile (xcaddy + caddy-brotli).
ensure_caddy_image() {
    local image
    image="$(image_of caddy)"
    if podman image exists "$image" 2>/dev/null; then
        ok "caddy image $image present"
        return 0
    fi
    step "Building $image (xcaddy + caddy-brotli; needs internet once)"
    podman build -t "$image" -f docker/caddy/Containerfile docker/caddy \
        || die "building $image failed. Check network access to docker.io and github.com."
    ok "built $image"
}

# ---------------------------------------------------------------------------
# systemd user units
# ---------------------------------------------------------------------------

# Per-service env files. They are derived from .env (the single source of
# truth) on every `up`/`restart`, hold secrets, and are therefore 0600 in a
# 0700 directory. Each service only receives the variables it needs — the app
# container, for instance, never sees the database root password.
write_env_files() {
    local db_name db_user db_pass db_root admin_user admin_pass trusted tz proxies
    db_name="$(env_or DB_NAME nextcloud)"
    db_user="$(env_or DB_USER nextcloud)"
    db_pass="$(env_need DB_PASSWORD)"
    db_root="$(env_need DB_ROOT_PASSWORD)"
    admin_user="$(env_need NEXTCLOUD_ADMIN_USER)"
    admin_pass="$(env_need NEXTCLOUD_ADMIN_PASSWORD)"
    trusted="$(env_need NEXTCLOUD_TRUSTED_DOMAINS)"
    tz="$(env_or TZ UTC)"

    # `cp .env.example .env` leaves these placeholders in place: refuse them.
    local secret
    for secret in "$db_pass" "$db_root" "$admin_pass"; do
        [ "$secret" != "change-me" ] \
            || die "$ENV_FILE still contains the placeholder 'change-me' for a password. Delete $ENV_FILE and run ./setup.sh up to generate real secrets."
    done

    # Trust forwarded headers only from the subnet Podman really gave the stack
    # network, unless .env says otherwise.
    proxies="$(env_get TRUSTED_PROXIES)"
    if [ -z "$proxies" ]; then
        ensure_network
        proxies="$(network_subnets)"
        [ -n "$proxies" ] || die "could not read the subnet of $NETWORK_NAME; set TRUSTED_PROXIES in $ENV_FILE."
    fi

    mkdir -p "$RUN_DIR"
    chmod 0700 "$RUN_DIR"
    local admin_env=""
    if ! instance_installed; then
        admin_env="NEXTCLOUD_ADMIN_USER=${admin_user}
NEXTCLOUD_ADMIN_PASSWORD=${admin_pass}
"
    fi
    (
        umask 077
        cat > "$RUN_DIR/db.env" <<EOF
MARIADB_ROOT_PASSWORD=${db_root}
MARIADB_DATABASE=${db_name}
MARIADB_USER=${db_user}
MARIADB_PASSWORD=${db_pass}
MARIADB_AUTO_UPGRADE=1
TZ=${tz}
EOF
        cat > "$RUN_DIR/app.env" <<EOF
MYSQL_HOST=db
MYSQL_DATABASE=${db_name}
MYSQL_USER=${db_user}
MYSQL_PASSWORD=${db_pass}
REDIS_HOST=redis
REDIS_HOST_PORT=6379
NEXTCLOUD_TRUSTED_DOMAINS=${trusted}
PHP_MEMORY_LIMIT=$(env_or PHP_MEMORY_LIMIT 512M)
PHP_UPLOAD_LIMIT=$(env_or PHP_UPLOAD_LIMIT 16G)
APACHE_BODY_LIMIT=$(env_or APACHE_BODY_LIMIT 0)
TZ=${tz}
TRUSTED_PROXIES=${proxies}
NEXTCLOUD_MAINTENANCE_WINDOW_START=$(env_or NEXTCLOUD_MAINTENANCE_WINDOW_START 1)
DEFAULT_PHONE_REGION=$(env_or DEFAULT_PHONE_REGION "")
NEXTCLOUD_OVERWRITE_CLI_URL=$(env_or NEXTCLOUD_OVERWRITE_CLI_URL "")
EOF
        printf '%s' "$admin_env" >> "$RUN_DIR/app.env"
        printf 'TZ=%s\n' "$tz" > "$RUN_DIR/cron.env"
        # Writable by the container's (host-mapped) user; the image's entrypoint
        # fills it with the Redis session-handler settings on every start.
        [ -e "$RUN_DIR/redis-session.ini" ] || : > "$RUN_DIR/redis-session.ini"
        printf 'NEXTCLOUD_UPSTREAM=%s:80\n' "$APP_CONTAINER" > "$RUN_DIR/caddy.env"
    )
}

# Has the Nextcloud instance been installed yet? (config.php inside the html
# volume says so.) The administrator credentials are only needed for that very
# first install, so they are put into the app environment only until then —
# afterwards they must not sit in the container's environment (`podman inspect`,
# /proc/<pid>/environ) for the rest of its life.
instance_installed() {
    local mp
    podman volume exists "$VOL_HTML" 2>/dev/null || return 1
    mp="$(podman volume inspect -f '{{.Mountpoint}}' "$VOL_HTML" 2>/dev/null)" || return 1
    podman unshare grep -qs "'installed' => true" "$mp/config/config.php"
}

# After the first install (or a restore) completes, rewrite the app environment
# without the administrator credentials and restart the web containers once.
scrub_install_secrets() {
    grep -q '^NEXTCLOUD_ADMIN_PASSWORD=' "$RUN_DIR/app.env" 2>/dev/null || return 0
    instance_installed || return 0
    step "Removing the first-install administrator credentials from the app environment"
    write_env_files
    sctl restart "$(unit_of app)"
    wait_for_web
    mark_applied
    ok "the app container no longer carries the administrator password"
}

# sed replacement-string escaping (\, & and the | delimiter).
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Render systemd/*.in into ~/.config/containers/systemd and let Quadlet turn
# them into services. Fails here — not at boot — if a unit does not generate.
render_units() {
    local f out data bind port https_port
    data="$(data_path)"
    bind="$(env_or NEXTCLOUD_BIND "$DEFAULT_BIND")"
    port="$(env_or NEXTCLOUD_PORT "$DEFAULT_HTTP_PORT")"
    https_port="$(env_or NEXTCLOUD_HTTPS_PORT "$DEFAULT_HTTPS_PORT")"

    # Who each service runs as, read from its image (or .env overrides).
    service_ids APP nextcloud
    service_ids DB db
    service_ids REDIS redis

    local run_abs
    case "$RUN_DIR" in /*) run_abs="$RUN_DIR" ;; *) run_abs="$PROJECT_DIR/$RUN_DIR" ;; esac
    mkdir -p "$QUADLET_DIR" "$RUN_DIR"
    chmod 0700 "$RUN_DIR"
    for f in "$UNIT_SRC_DIR"/*.in; do
        [ -e "$f" ] || die "no unit templates in $UNIT_SRC_DIR/"
        out="$QUADLET_DIR/$(basename "${f%.in}")"
        sed \
            -e "s|@PROJECT_DIR@|$(sed_esc "$PROJECT_DIR")|g" \
            -e "s|@RUN_DIR@|$(sed_esc "$run_abs")|g" \
            -e "s|@NETWORK_NAME@|$(sed_esc "$NETWORK_NAME")|g" \
            -e "s|@VOL_HTML@|$(sed_esc "$VOL_HTML")|g" -e "s|@VOL_DB@|$(sed_esc "$VOL_DB")|g" \
            -e "s|@VOL_REDIS@|$(sed_esc "$VOL_REDIS")|g" -e "s|@VOL_CADDY@|$(sed_esc "$VOL_CADDY")|g" \
            -e "s|@DATA_HOST_PATH@|$(sed_esc "$data")|g" \
            -e "s|@USER@|$(sed_esc "$(me_user)")|g" \
            -e "s|@BIND@|$(sed_esc "$bind")|g" \
            -e "s|@PORT@|$(sed_esc "$port")|g" \
            -e "s|@HTTPS_PORT@|$(sed_esc "$https_port")|g" \
            -e "s|@NEXTCLOUD_IMAGE@|$(sed_esc "$(image_of nextcloud)")|g" \
            -e "s|@DB_IMAGE@|$(sed_esc "$(image_of db)")|g" \
            -e "s|@REDIS_IMAGE@|$(sed_esc "$(image_of redis)")|g" \
            -e "s|@CADDY_IMAGE@|$(sed_esc "$(image_of caddy)")|g" \
            -e "s|@APP_UID@|$APP_UID|g" -e "s|@APP_GID@|$APP_GID|g" -e "s|@APP_RUN_USER@|$(sed_esc "$APP_RUN_USER")|g" \
            -e "s|@DB_UID@|$DB_UID|g" -e "s|@DB_GID@|$DB_GID|g" -e "s|@DB_RUN_USER@|$(sed_esc "$DB_RUN_USER")|g" \
            -e "s|@REDIS_UID@|$REDIS_UID|g" -e "s|@REDIS_GID@|$REDIS_GID|g" -e "s|@REDIS_RUN_USER@|$(sed_esc "$REDIS_RUN_USER")|g" \
            -e "s|@DB_BUFFER_POOL@|$(sed_esc "$(env_or DB_INNODB_BUFFER_POOL 512M)")|g" \
            "$f" > "$out.tmp"
        if grep -q '@[A-Z_]*@' "$out.tmp"; then
            rm -f "$out.tmp"
            die "unresolved placeholder in $f"
        fi
        mv -f "$out.tmp" "$out"
    done

    # Dry-run the generator: surfaces unit syntax errors immediately.
    QUADLET_UNIT_DIRS="$QUADLET_DIR" "$QUADLET_BIN" -dryrun -user >/dev/null 2>"$RUN_DIR/quadlet.err" \
        || { cat "$RUN_DIR/quadlet.err" >&2; die "Quadlet could not generate the units (see above)."; }
    [ -n "${NEXTCLOUD_NO_RELOAD:-}" ] || sctl daemon-reload
    ok "systemd user units installed in $QUADLET_DIR"
}

cmd_install() {
    ensure_env
    require_systemd
    mkdir -p "$(data_path)" || die "cannot create the data directory $(data_path)."
    ensure_tls
    ensure_caddy_image
    render_units
    write_env_files
    ensure_linger
}

# Hash of everything the running services were configured from (rendered units
# and per-service env files). If it differs from the hash recorded when the
# services were last started, the configuration changed but was not applied.
config_fingerprint() {
    { cat "$QUADLET_DIR"/nextcloud*.container "$QUADLET_DIR"/nextcloud*.network "$RUN_DIR"/*.env 2>/dev/null || true; } \
        | sha256sum | cut -d' ' -f1
}
mark_applied() { config_fingerprint > "$RUN_DIR/.applied"; }
warn_if_drift() {
    if stack_running && [ -f "$RUN_DIR/.applied" ] && [ "$(config_fingerprint)" != "$(cat "$RUN_DIR/.applied")" ]; then
        warn "the configuration changed since the services were started; run ./setup.sh restart to apply it."
    fi
}

stack_running() {
    local s
    for s in "${SERVICES[@]}"; do
        sctl is-active --quiet "$(unit_of "$s")" && return 0
    done
    return 1
}

start_stack() {
    local s units=()
    sctl reset-failed 2>/dev/null || true
    for s in "${SERVICES[@]}"; do units+=("$(unit_of "$s")"); done
    sctl start "${units[@]}" || {
        warn "a unit failed to start:"
        sctl --no-pager status "${units[@]}" 2>&1 | sed 's/^/     /' >&2 || true
        die "see 'journalctl --user -u nextcloud-<svc>' for details."
    }
}

stop_stack() {
    local i units=()
    for ((i = ${#SERVICES[@]} - 1; i >= 0; i--)); do units+=("$(unit_of "${SERVICES[i]}")"); done
    sctl stop "${units[@]}" 2>/dev/null || true
}

# A container is ours-and-managed only when its systemd label names ITS OWN
# Quadlet unit (nextcloud-app -> nextcloud-app.service). podman-compose also
# sets that label, to podman-compose@nextcloud.service, so "has a label" is not
# enough to tell the two apart.
is_legacy_container() {
    local c="$1" unit
    unit="$(podman inspect -f '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c" 2>/dev/null || true)"
    [ "$unit" != "$(unit_of "${c#nextcloud-}")" ]
}

# Containers named nextcloud-* that are NOT owned by a systemd unit (left over
# from the old podman-compose setup) would collide with the units' names and
# ports. Remove them; volumes and data are untouched.
legacy_cleanup() {
    local svc c found=0
    for svc in "${SERVICES[@]}"; do
        c="nextcloud-$svc"
        podman container exists "$c" 2>/dev/null || continue
        if is_legacy_container "$c"; then
            [ "$found" -eq 0 ] && step "Removing legacy (non-Quadlet) containers"
            found=1
            # --depend also removes containers that depend on this one
            # (compose made app/cron depend on db/redis).
            podman rm -f --depend "$c" >/dev/null \
                || die "could not remove legacy container $c"
            ok "removed legacy container $c"
        fi
    done
    for svc in "${SERVICES[@]}"; do
        c="nextcloud-$svc"
        ! podman container exists "$c" 2>/dev/null || ! is_legacy_container "$c" \
            || die "legacy container $c is still present."
    done
    return 0
}

# ---------------------------------------------------------------------------
# File ownership
# ---------------------------------------------------------------------------
#
# Rootless Podman maps container uids onto sub-uids of yours, so by default
# www-data (33) writes as host uid 100032 — a user that does not exist and that
# your login (and Samba, which acts as you) cannot write as. The units use
# `UserNS=keep-id`, which maps www-data/mysql/redis onto YOU. Anything written
# before that change is still owned by a sub-uid; this migrates it.
#
# `podman unshare` enters Podman's default user namespace, in which the
# invoking user appears under some id of that namespace (always root's, but we
# ask instead of assuming). "Owned by me on the host" is "owned by that id
# there", so we compare against, and chown to, whatever `podman unshare id`
# reports.

ns_ids() { podman unshare id -u; podman unshare id -g; }

foreign_owned() {
    local uid
    uid="$(podman unshare id -u)"
    podman unshare find "$1" -not -uid "$uid" -print -quit 2>/dev/null | grep -q .
}

# The bind-mounted data directory needs an empty mount-point directory inside
# the html volume. If Podman has to create it, it is owned by the container's
# root (a sub-uid); create the volume and that directory as ourselves instead.
prepare_html_volume() {
    local mp
    podman volume exists "$VOL_HTML" 2>/dev/null || podman volume create "$VOL_HTML" >/dev/null
    mp="$(podman volume inspect -f '{{.Mountpoint}}' "$VOL_HTML")"
    podman unshare mkdir -p "$mp/data"
}

ensure_ownership() {
    local targets=() vol mp d t fixed=0
    prepare_html_volume
    d="$(data_path)"
    [ -d "$d" ] && targets+=("$d")
    for vol in "$VOL_HTML" "$VOL_DB" "$VOL_REDIS" "$VOL_CADDY"; do
        podman volume exists "$vol" 2>/dev/null || continue
        mp="$(podman volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        [ -n "$mp" ] && targets+=("$mp")
    done

    for t in "${targets[@]}"; do
        if foreign_owned "$t"; then
            if stack_running; then
                die "files in $t are not owned by you, but the stack is running. Run: ./setup.sh down && ./setup.sh up"
            fi
            step "Giving $t to $(me_user) (it contains files owned by a sub-uid)"
            podman unshare sh -c 'chown -R "$(id -u):$(id -g)" "$1"' _ "$t"
            fixed=1
        fi
    done
    [ "$fixed" -eq 1 ] && ok "ownership migrated" || ok "all stack files are owned by $(me_user)"
    return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Is a host port free (or already held by the given systemd unit's container)?
check_port() {
    local p="$1" label="$2" bind="$3" unit="$4"
    if [[ ! "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        die "$label='$p' is not a valid TCP port."
    fi
    if command -v ss >/dev/null 2>&1 && ss -ltnuH "sport = :${p}" 2>/dev/null | grep -q .; then
        # Our own unit may legitimately hold it.
        if ! sctl is-active --quiet "$unit" 2>/dev/null; then
            warn "port ${p} is already in use by another process:"
            ss -ltnup "sport = :${p}" 2>/dev/null | sed 's/^/     /' >&2
            die "free it, or set $label in $ENV_FILE to something else."
        fi
    fi
    ok "host port ${p} available (bind ${bind})"
}

preflight() {
    step "Preflight checks"

    require_systemd
    ok "$(podman --version); systemd --user reachable; Quadlet at $QUADLET_BIN"

    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        ok "rootless podman"
    else
        warn "running rootful podman — fine, but rootless is the safer default"
    fi

    local bind port https_port
    bind="$(env_or NEXTCLOUD_BIND "$DEFAULT_BIND")"
    port="$(env_or NEXTCLOUD_PORT "$DEFAULT_HTTP_PORT")"
    https_port="$(env_or NEXTCLOUD_HTTPS_PORT "$DEFAULT_HTTPS_PORT")"
    check_port "$port" "NEXTCLOUD_PORT" "$bind" "$(unit_of app)"
    check_port "$https_port" "NEXTCLOUD_HTTPS_PORT" "$bind" "$(unit_of caddy)"

    local d
    d="$(data_path)"
    mkdir -p "$d" || die "cannot create the data directory $d (DATA_HOST_PATH)."
    [ -w "$d" ] || die "the data directory $d is not writable by $(me_user)."
    ok "data directory $d (owner: $(stat -c %U "$d"))"

    # A fresh install (no html volume yet) refuses a non-empty data directory
    # ("Login is invalid because files already exist for this user") and would
    # retry for minutes. Say so now.
    if ! podman volume exists "$VOL_HTML" 2>/dev/null && [ -n "$(ls -A -- "$d" 2>/dev/null)" ]; then
        die "no Nextcloud instance exists yet, but the data directory is not empty: $d
     A fresh install needs an empty directory. Either restore a backup
     (./setup.sh restore) or empty/move that directory, then run ./setup.sh up."
    fi

    # Mounting a directory over /docker-entrypoint-hooks.d hides the image's
    # own hook folders, so ours must provide them too.
    local hooks_dir="config/nextcloud-hooks"
    [ -d "$hooks_dir" ] || die "$hooks_dir is missing."
    for sub in pre-installation post-installation before-starting pre-upgrade post-upgrade; do
        [ -d "$hooks_dir/$sub" ] || die "$hooks_dir/$sub is missing."
    done
    [ -x "$hooks_dir/before-starting/10-nextcloud-tuning.sh" ] \
        || die "$hooks_dir/before-starting/10-nextcloud-tuning.sh must exist and be executable."
    ok "container hooks present and executable"

    mkdir -p backups
    ensure_tls
}

# ---------------------------------------------------------------------------
# Waiting for the web interface
# ---------------------------------------------------------------------------

# Probe http://<bind or loopback>:$port/status.php for an installed instance.
# Uses curl when available, otherwise a bash /dev/tcp request.
probe_status() {
    local port="$1" host body=""
    host="$(probe_host)"
    local url="http://${host}:${port}/status.php"

    if command -v curl >/dev/null 2>&1; then
        body="$(curl -fsS --max-time 10 --ipv4 "$url" 2>/dev/null || true)"
    else
        exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null || return 1
        printf 'GET /status.php HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$host" >&3
        body="$(cat <&3 2>/dev/null || true)"
        exec 3<&- 3>&-
    fi

    printf '%s' "$body" | grep -q '"installed": *true'
}

wait_for_web() {
    local port elapsed=0 interval=5 down=0
    port="$(env_or NEXTCLOUD_PORT "$DEFAULT_HTTP_PORT")"

    step "Waiting for Nextcloud to finish installing (up to ${STARTUP_TIMEOUT}s)"
    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        if probe_status "$port"; then
            ok "web interface is up and reported as installed (after ${elapsed}s)"
            return 0
        fi

        # Fail fast instead of waiting out the timeout if the app keeps dying.
        # The unit restarts itself (Restart=always), so one brief gap is
        # normal; only give up after several consecutive "not running" polls.
        if [ "$(podman inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2>/dev/null)" != "true" ]; then
            down=$((down + 1))
            if [ "$down" -ge 6 ]; then
                warn "the app container is not staying up. Last 30 log lines:"
                podman logs --tail 30 "$APP_CONTAINER" 2>&1 | sed 's/^/     /' >&2
                sctl --no-pager status "$(unit_of app)" 2>&1 | sed 's/^/     /' >&2 || true
                die "startup aborted — see the log excerpt above."
            fi
        else
            down=0
        fi

        printf '    ... still installing (%ss)\n' "$elapsed"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "timed out after ${STARTUP_TIMEOUT}s. Last 40 log lines:"
    podman logs --tail 40 "$APP_CONTAINER" 2>&1 | sed 's/^/     /' >&2
    die "the web interface never came up."
}

# Block until MariaDB reports healthy. Used by `restore`, which must not touch
# the database before the server is accepting connections.
wait_for_db() {
    local elapsed=0 interval=3 status

    step "Waiting for the database to accept connections"
    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        status="$(podman inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                  "$DB_CONTAINER" 2>/dev/null || echo missing)"

        case "$status" in
            healthy) ok "database is healthy (after ${elapsed}s)"; return 0 ;;
            missing) die "$DB_CONTAINER does not exist. Run ./setup.sh status." ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "the database never reported healthy. Last 40 log lines:"
    podman logs --tail 40 "$DB_CONTAINER" 2>&1 | sed 's/^/     /' >&2
    die "cannot continue without a database."
}

# ---------------------------------------------------------------------------
# Volume helpers — used by backup and restore
# ---------------------------------------------------------------------------
#
# Both directions run a throwaway alpine container as YOU (`--userns=keep-id`
# makes the container's default user the invoking user's own uid/gid). A
# non-root tar never chowns, so everything it extracts is owned by you whatever
# owners the archive recorded — including archives made before the stack ran as
# you. No uid or gid is written down anywhere.

# Empty the host data directory (as YOU, via keep-id; nothing else may delete
# files there). The restore's throwaway install requires it to be empty — the
# Nextcloud installer refuses to create the admin account when that user's
# folder already exists — and the restore replaces its contents anyway.
data_wipe() {
    local d
    d="$(data_path)"
    [ -d "$d" ] || die "DATA_HOST_PATH does not exist: $d"
    podman run --rm --userns=keep-id \
        -v "${d}:/target" \
        "$(image_of helper)" \
        sh -c 'rm -rf /target/* /target/.[!.]* /target/..?*' \
        || die "could not empty $d."
    [ -z "$(ls -A -- "$d")" ] \
        || die "$d is not empty after wiping (files owned by another user? run ./setup.sh down, then ./setup.sh up to migrate ownership)."
}

# Wipe a whole volume and unpack an archive that was created with
# `tar -C <parent> <dir>`, i.e. whose entries all carry one leading directory
# that has to be stripped. The helper runs as YOU (`--userns=keep-id`), so the
# extracted files are owned by you whatever owners the archive recorded.
volume_restore() {
    local archive="$1" backup_dir="$2"

    # Restore user data into the host path specified in .env.
    local host_data_path
    host_data_path="$(data_path)"
    if [ -z "$host_data_path" ] || [ ! -d "$host_data_path" ]; then
        die "DATA_HOST_PATH not set or directory does not exist: $host_data_path"
    fi

    podman run --rm --userns=keep-id \
        -v "${host_data_path}:/target" \
        -v "${backup_dir}:/backup:Z" \
        "$(image_of helper)" \
        sh -c "rm -rf /target/* /target/.[!.]* 2>/dev/null || true
               tar xzf /backup/${archive} -C /target --strip-components=1 --no-same-owner"
}

# Replace a single sub-directory inside a volume, keeping the archive's own
# top-level name. Used for /var/www/html/config, which lives in the html volume
# alongside the program files we must not touch.
volume_restore_subdir() {
    local volume="$1" subdir="$2" archive="$3" backup_dir="$4"

    podman run --rm --userns=keep-id \
        -v "${volume}:/target" \
        -v "${backup_dir}:/backup:Z" \
        "$(image_of helper)" \
        sh -c "rm -rf /target/${subdir}
               tar xzf /backup/${archive} -C /target --no-same-owner"
}

# Capture a whole volume, storing it as <dir>/<name>.tar.gz.
volume_backup() {
    local volume="$1" name="$2" backup_dir="$3"

    podman run --rm --userns=keep-id \
        -v "${volume}:/source:ro" \
        -v "${backup_dir}:/backup:Z" \
        "$(image_of helper)" \
        tar czf "/backup/${name}.tar.gz" -C /source .
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

print_access_info() {
    local port https_port bind lan_ip host
    port="$(env_or NEXTCLOUD_PORT "$DEFAULT_HTTP_PORT")"
    https_port="$(env_or NEXTCLOUD_HTTPS_PORT "$DEFAULT_HTTPS_PORT")"
    bind="$(env_or NEXTCLOUD_BIND "$DEFAULT_BIND")"
    lan_ip="$(detect_lan_ip)"
    host="$(hostname 2>/dev/null || echo localhost)"

    printf '\n%s%s  Nextcloud is ready%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"

    printf '  HTTPS (recommended, self-signed certificate)\n'
    if [ "$bind" = "127.0.0.1" ] || [ "$bind" = "localhost" ]; then
        printf '    On this machine   %shttps://localhost:%s%s\n' "$C_BLUE" "$https_port" "$C_RESET"
    else
        printf '    On this machine   %shttps://localhost:%s%s\n' "$C_BLUE" "$https_port" "$C_RESET"
        printf '    From the LAN      %shttps://%s:%s%s\n' "$C_BLUE" "${lan_ip:-<host-lan-ip>}" "$https_port" "$C_RESET"
        [ -n "$host" ] && printf '    By host name      %shttps://%s:%s%s\n' "$C_BLUE" "$host" "$https_port" "$C_RESET"
    fi
    printf '  Plain HTTP\n'
    printf '    On this machine   %shttp://localhost:%s%s\n' "$C_BLUE" "$port" "$C_RESET"
    [ "$bind" != "127.0.0.1" ] && [ "$bind" != "localhost" ] \
        && printf '    From the LAN      %shttp://%s:%s%s\n' "$C_BLUE" "${lan_ip:-<host-lan-ip>}" "$port" "$C_RESET"

    printf '\n  Administrator     %s\n' "$(env_get NEXTCLOUD_ADMIN_USER)"
    printf '  Password          %s\n' "$(env_get NEXTCLOUD_ADMIN_PASSWORD)"
    printf '  Credentials file  %s\n\n' "$PROJECT_DIR/$ENV_FILE"

    printf '  %sKeep this password: it is stored in .env and nowhere else.%s\n\n' "$C_DIM" "$C_RESET"

    printf '  Useful next steps\n'
    printf '    ./setup.sh occ status\n'
    printf '    ./setup.sh status\n'
    printf '    systemctl --user status nextcloud-app\n'
    printf '    ./setup.sh down\n\n'
}

cmd_up() {
    ensure_env
    preflight
    ensure_caddy_image
    render_units
    write_env_files
    ensure_linger

    legacy_cleanup
    ensure_ownership

    warn_if_drift
    step "Starting the services (systemctl --user)"
    start_stack
    mark_applied

    wait_for_web
    scrub_install_secrets
    print_access_info
}

cmd_down() {
    require_systemd
    step "Stopping the services (volumes and data are preserved)"
    stop_stack
    ok "stopped. Data is still in $(data_path) and the nextcloud-* volumes"
}

cmd_restart() {
    ensure_env
    require_systemd
    step "Re-rendering the units and restarting to pick up configuration changes"
    ensure_tls
    ensure_caddy_image
    render_units
    write_env_files
    stop_stack
    legacy_cleanup
    ensure_ownership
    start_stack
    mark_applied
    wait_for_web
    print_access_info
}

cmd_status() {
    require_systemd
    step "systemd user units"
    local s
    for s in "${SERVICES[@]}"; do
        printf '  %-28s %-9s %-9s %s\n' "$(unit_of "$s")" \
            "$(sctl is-active "$(unit_of "$s")" 2>/dev/null || true)" \
            "$(sctl is-enabled "$(unit_of "$s")" 2>/dev/null || echo generated)" \
            "restarts=$(sctl show "$(unit_of "$s")" -p NRestarts --value 2>/dev/null)"
    done
    printf '  linger: %s\n' "$(loginctl show-user "$(me_user)" -p Linger --value 2>/dev/null)"

    step "Containers"
    podman ps -a --filter "name=^nextcloud-" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

    step "Volumes"
    podman volume ls --filter "name=^nextcloud-" --format 'table {{.Name}}\t{{.Driver}}' || true

    step "Ownership (everything should belong to $(me_user))"
    local d bad
    d="$(data_path)"
    if [ -d "$d" ]; then
        bad="$(find "$d" -not -user "$(me_user)" 2>/dev/null | wc -l)"
        printf '  %-14s %s  (%s entries not owned by %s)\n' "data" "$d" "$bad" "$(me_user)"
    fi
    local vol mount
    for vol in "$VOL_HTML" "$VOL_DB" "$VOL_REDIS" "$VOL_CADDY"; do
        podman volume exists "$vol" 2>/dev/null || continue
        mount="$(podman volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        [ -n "$mount" ] || continue
        if foreign_owned "$mount"; then
            printf '  %-22s %sforeign-owned files present%s\n' "$vol" "$C_YELLOW" "$C_RESET"
        else
            printf '  %-22s ok\n' "$vol"
        fi
    done

    host_advice

    step "Health"
    local port https_port
    port="$(env_or NEXTCLOUD_PORT "$DEFAULT_HTTP_PORT")"
    https_port="$(env_or NEXTCLOUD_HTTPS_PORT "$DEFAULT_HTTPS_PORT")"
    if probe_status "$port"; then
        ok "Nextcloud answers on http port ${port} and reports itself installed"
    else
        warn "Nextcloud did not answer correctly on http port ${port}"
    fi
    if curl -fsSk --max-time 10 "https://$(probe_host):${https_port}/status.php" 2>/dev/null | grep -q '"installed": *true'; then
        ok "Nextcloud answers on https port ${https_port}"
    else
        warn "Nextcloud did not answer correctly on https port ${https_port}"
    fi
}

# Optional host tuning that needs root; informational only.
host_advice() {
    local oc rmem
    oc="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo '?')"
    rmem="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)"
    [ "$oc" = "1" ] && [ "${rmem:-0}" -ge 7340032 ] 2>/dev/null && return 0
    step "Host tuning (optional, needs root)"
    [ "$oc" = "1" ] || printf '  vm.overcommit_memory=%s (Redis prefers 1):  sudo sysctl vm.overcommit_memory=1\n' "$oc"
    [ "${rmem:-0}" -ge 7340032 ] 2>/dev/null || printf '  net.core.rmem_max=%s (HTTP/3 wants >=7340032):  sudo sysctl net.core.rmem_max=7500000\n' "$rmem"
    return 0
}

cmd_logs() {
    require_systemd
    local service="${1:-}"
    if [ -z "$service" ]; then
        journalctl --user -f -n 100 -u 'nextcloud-*'
    else
        case "$service" in
            app|db|redis|cron|caddy) podman logs -f --tail=100 "nextcloud-$service" ;;
            *) die "unknown service '$service' (expected: app, db, redis, cron, caddy)" ;;
        esac
    fi
}

cmd_occ() {
    require_cmd podman
    if ! podman container exists "$APP_CONTAINER" 2>/dev/null; then
        die "$APP_CONTAINER is not running. Start it with: ./setup.sh up"
    fi
    # stdin always (so piped input works); a TTY too when interactive, so
    # commands that prompt (user:add, user:resetpassword) work.
    local flags=(-i)
    if [ -t 0 ] && [ -t 1 ]; then flags+=(-t); fi
    podman exec "${flags[@]}" -u "$(app_user)" "$APP_CONTAINER" php /var/www/html/occ "$@"
}

cmd_creds() {
    [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run ./setup.sh up first."
    printf 'Administrator  %s\n' "$(env_get NEXTCLOUD_ADMIN_USER)"
    printf 'Password       %s\n' "$(env_get NEXTCLOUD_ADMIN_PASSWORD)"
}

cmd_backup() {
    require_cmd podman
    local quiesce=0
    case "${1:-}" in
        --quiesce) quiesce=1 ;;
        "") ;;
        *) die "unknown option '$1' (expected: --quiesce)" ;;
    esac
    local stamp dir dbname archive
    archive="data"
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="$PROJECT_DIR/backups/$stamp"
    dbname="$(env_or DB_NAME nextcloud)"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    # A failed backup must not leave a half-written directory that a later
    # `restore` would pick as "newest".
    PARTIAL_BACKUP="$dir"
    BACKUP_MAINTENANCE=0
    # On any exit: leave maintenance mode if we entered it, drop a partial backup.
    trap 'if [ "${BACKUP_MAINTENANCE:-0}" = 1 ]; then cmd_occ maintenance:mode --off >/dev/null 2>&1 || true; fi
          if [ -n "${PARTIAL_BACKUP:-}" ]; then rm -rf -- "$PARTIAL_BACKUP"; fi' EXIT

    # config.php FIRST, before maintenance mode: Nextcloud stores its maintenance
    # flag in config.php, so an archive taken afterwards would restore an instance
    # that is stuck in maintenance mode. It holds only static identity, so it has
    # no consistency requirement with the live data.
    step "Archiving config.php"
    # config.php holds the instanceid, secret and passwordsalt. Without it a
    # restored database is an orphan: the instance id would no longer match and
    # Nextcloud would refuse to log anyone in. It is tiny, so back it up too.
    # It lives inside the html volume, so grab just that one directory.
    podman run --rm --userns=keep-id \
        -v "${VOL_HTML}:/source:ro" \
        -v "$dir:/backup:Z" \
        "$(image_of helper)" \
        tar czf /backup/config.tar.gz -C /source config
    ok "config.tar.gz ($(du -h "$dir/config.tar.gz" | cut -f1))"

    if [ "$quiesce" = 1 ]; then
        step "Entering maintenance mode (database and files are captured in the same state)"
        cmd_occ maintenance:mode --on >/dev/null
        BACKUP_MAINTENANCE=1
        ok "maintenance mode on"
    fi

    step "Dumping the database"
    # --single-transaction gives a consistent snapshot without locking the
    # tables, so a running instance keeps serving requests during the dump.
    podman exec "$DB_CONTAINER" \
        sh -c "exec mariadb-dump --single-transaction --quick --routines --events \
               -u root -p\"\$MARIADB_ROOT_PASSWORD\" \"$dbname\"" \
        > "$dir/database.sql"
    gzip -9 "$dir/database.sql"
    ok "database.sql.gz ($(du -h "$dir/database.sql.gz" | cut -f1))"

    step "Archiving user data"
    # Back up the user data directory from the host path specified in .env.
    # We tar the host directory directly rather than using a named volume,
    # since the data is now accessed via bind mount.
    local host_data_path
    host_data_path="$(data_path)"
    if [ -z "$host_data_path" ] || [ ! -d "$host_data_path" ]; then
        warn "DATA_HOST_PATH not set or directory does not exist; skipping data backup"
    else
        podman run --rm --userns=keep-id \
            -v "${host_data_path}:/source" \
            -v "$dir:/backup:Z" \
            "$(image_of helper)" \
            tar czf "/backup/${archive}.tar.gz" -C /source .
        ok "data.tar.gz ($(du -h "$dir/data.tar.gz" | cut -f1))"
    fi

    step "Copying configuration"
    cp -- "$ENV_FILE" "$dir/env.backup"
    cp -a -- "$UNIT_SRC_DIR" "$dir/systemd.backup"
    chmod 0600 "$dir/env.backup"

    if [ "$BACKUP_MAINTENANCE" = 1 ]; then
        cmd_occ maintenance:mode --off >/dev/null
        BACKUP_MAINTENANCE=0
        ok "maintenance mode off"
    fi
    PARTIAL_BACKUP=""
    trap - EXIT

    printf '\n%sBackup complete:%s %s\n' "$C_GREEN" "$C_RESET" "$dir"
    printf 'Restore it with:  ./setup.sh restore %s\n\n' "$stamp"
}

# Is DIR a complete backup set?
backup_complete() {
    local f
    for f in database.sql.gz data.tar.gz config.tar.gz env.backup; do
        [ -f "$1/$f" ] || return 1
    done
}

# Newest COMPLETE directory under backups/, or die trying.
newest_backup() {
    local dir
    while IFS= read -r dir; do
        if backup_complete "$dir"; then printf '%s' "$dir"; return 0; fi
    done < <(find backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort -r)
    die "no complete backup found in $PROJECT_DIR/backups — run ./setup.sh backup first."
}

# Refuse a backup that cannot be read BEFORE anything destructive happens.
validate_backup() {
    local dir="$1"
    gzip -t "$dir/database.sql.gz" 2>/dev/null || die "$dir/database.sql.gz is corrupt."
    gzip -t "$dir/data.tar.gz"     2>/dev/null || die "$dir/data.tar.gz is corrupt."
    gzip -t "$dir/config.tar.gz"   2>/dev/null || die "$dir/config.tar.gz is corrupt."
    tar tzf "$dir/data.tar.gz"   >/dev/null 2>&1 || die "$dir/data.tar.gz is not a readable archive."
    tar tzf "$dir/config.tar.gz" 2>/dev/null | grep -q '^config/config\.php$' \
        || die "$dir/config.tar.gz does not contain config/config.php."
    ok "backup archives verified"
}

# Set KEY=VALUE in .env (replace the line, or append it).
env_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=$(sed_esc "$val")|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

# Remove the stack's containers (not volumes), in any order, and verify.
remove_containers() {
    local svc
    for svc in "${SERVICES[@]}"; do
        podman rm -f "nextcloud-$svc" >/dev/null 2>&1 || true
    done
    for svc in "${SERVICES[@]}"; do
        ! podman container exists "nextcloud-$svc" 2>/dev/null \
            || die "container nextcloud-$svc could not be removed."
    done
}

# Remove the given volumes and verify they are really gone.
remove_volumes() {
    local v
    podman volume rm -f "$@" >/dev/null 2>&1 || true
    for v in "$@"; do
        ! podman volume exists "$v" 2>/dev/null || die "volume $v could not be removed."
    done
}

cmd_restore() {
    require_systemd
    data_path >/dev/null
    # Starting the stack below also starts caddy, whose ./tls mount must exist.
    ensure_tls

    local backup_dir="${1:-}" dbname answer f
    if [ -z "$backup_dir" ]; then
        backup_dir="$(newest_backup)"
    elif [ -d "$backup_dir" ]; then
        :
    elif [ -d "backups/$backup_dir" ]; then
        # Accept the bare timestamp that `backup` prints, not just a path.
        backup_dir="backups/$backup_dir"
    elif [ -d "$INVOKE_DIR/$backup_dir" ]; then
        # A path relative to where the command was typed.
        backup_dir="$INVOKE_DIR/$backup_dir"
    fi
    [ -d "$backup_dir" ] || die "no such backup directory: $backup_dir"
    # Absolute path: it is mounted into a container further down.
    backup_dir="$(cd -- "$backup_dir" && pwd)"

    backup_complete "$backup_dir" || die "$backup_dir is not a complete backup set."
    validate_backup "$backup_dir"

    warn "This REPLACES the current instance — user files, the database and"
    warn "config.php — with the contents of:"
    warn "  $backup_dir"
    warn "Everything in this directory will be DELETED first:"
    warn "  $(data_path)"
    warn "The current contents are lost. Take a backup first if you want them."
    printf '\nType %sRESTORE%s to confirm: ' "$C_BOLD" "$C_RESET"
    read -r answer || true
    [ "$answer" = "RESTORE" ] || die "aborted; nothing was restored."

    step "Applying the backup's credentials to $ENV_FILE"
    # The dump's tables belong to the database/admin credentials of the
    # instance that was backed up; restoring one without the other yields an
    # instance that cannot reach its own database. Everything machine-specific
    # (ports, bind address, data path, images, ...) stays as it is on THIS host.
    if [ -f "$ENV_FILE" ]; then
        f="$ENV_FILE.pre-restore.$(date +%Y%m%d-%H%M%S)"
        cp -p -- "$ENV_FILE" "$f"
        ok "previous $ENV_FILE saved as $f"
        local key val
        for key in DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD; do
            val="$(sed -n "s/^${key}=//p" "$backup_dir/env.backup" | tail -1)"
            [ -n "$val" ] && env_set "$key" "$val"
        done
        ok "database and administrator credentials taken from the backup"
    else
        ( umask 077; cp -- "$backup_dir/env.backup" "$ENV_FILE" )
        warn "no $ENV_FILE existed; used the backup's. Check DATA_HOST_PATH and the ports in it."
    fi
    chmod 0600 "$ENV_FILE"
    data_path >/dev/null

    step "Clearing the old instance (containers and volumes; caddy's certificate state is kept)"
    # Restoring onto live volumes would leave MariaDB with its OLD passwords
    # (they are only applied to an empty volume) and an installed instance
    # whose data directory is about to be emptied. Start from nothing instead.
    stop_stack
    remove_containers
    remove_volumes "$VOL_HTML" "$VOL_DB" "$VOL_REDIS"
    ok "containers and the html/db/redis volumes removed"

    ensure_caddy_image
    render_units
    write_env_files

    step "Emptying the data directory $(data_path)"
    # Ownership first: files left by an older, sub-uid setup cannot be removed
    # by an unprivileged helper.
    ensure_ownership
    data_wipe
    ok "data directory emptied (the backup's user files are restored below)"

    step "Creating volumes and containers from scratch"
    # This runs the image's own installer once. That throwaway instance is
    # completely overwritten a moment later; it exists because a named volume
    # is only populated from the image while it is still empty, and we need the
    # program files in place before we can put the backed-up config.php on top.
    start_stack

    wait_for_db
    wait_for_web

    step "Stopping the web services while data is written"
    sctl stop "$(unit_of caddy)" "$(unit_of cron)" "$(unit_of app)" 2>/dev/null || true
    ok "caddy, app and cron stopped (database and redis stay up)"

    dbname="$(env_or DB_NAME nextcloud)"

    step "Replacing the database"
    podman exec "$DB_CONTAINER" sh -c \
        "mariadb -u root -p\"\$MARIADB_ROOT_PASSWORD\" -e \
         'DROP DATABASE IF EXISTS $dbname; \
          CREATE DATABASE $dbname CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;'"
    gunzip -c "$backup_dir/database.sql.gz" \
        | podman exec -i "$DB_CONTAINER" sh -c \
            "exec mariadb -u root -p\"\$MARIADB_ROOT_PASSWORD\" $dbname"
    ok "database imported from database.sql.gz"

    step "Restoring user data"
    volume_restore "data.tar.gz" "$backup_dir"
    ok "user files restored into data directory"

    step "Restoring config.php"
    volume_restore_subdir "$VOL_HTML" "config" "config.tar.gz" "$backup_dir"
    ok "config.php restored into $VOL_HTML"

    step "Starting the web services again"
    start_stack
    wait_for_web
    scrub_install_secrets

    # A restored instance must be usable: if the backup carried the maintenance
    # flag (e.g. it was taken while the source was in maintenance mode), clear it.
    if cmd_occ maintenance:mode 2>/dev/null | grep -qi 'enabled'; then
        warn "the restored configuration had maintenance mode enabled; switching it off"
        cmd_occ maintenance:mode --off >/dev/null
    fi

    step "Verifying the restored instance"
    local instanceid users
    instanceid="$(podman exec -u "$(app_user)" "$APP_CONTAINER" php /var/www/html/occ config:system:get instanceid 2>/dev/null || echo '?')"
    users="$(podman exec -u "$(app_user)" "$APP_CONTAINER" php /var/www/html/occ user:list 2>/dev/null | wc -l)"
    ok "instance id   ${instanceid}"
    ok "user accounts ${users}"

    printf '\n%sRestore complete.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf 'Log in with the administrator credentials from the restored backup:\n\n'
    cmd_creds
    printf '\n'
    print_access_info
}

# Stop the services and remove the rendered units and generated env files.
# Volumes, the data directory, tls/ and .env are KEPT: `./setup.sh up` brings
# the same instance back.
cmd_uninstall() {
    require_systemd
    step "Stopping the services and removing the systemd units"
    stop_stack
    remove_containers
    sctl stop nextcloud-network.service 2>/dev/null || true
    local f
    for f in "$QUADLET_DIR"/nextcloud*.container "$QUADLET_DIR"/nextcloud*.network; do
        [ -e "$f" ] && rm -f -- "$f" && ok "removed $(basename "$f")"
    done
    rm -rf -- "$RUN_DIR"
    [ -n "${NEXTCLOUD_NO_RELOAD:-}" ] || sctl daemon-reload
    sctl reset-failed 2>/dev/null || true
    ok "uninstalled (volumes, data, .env and tls/ are kept; ./setup.sh up reinstalls)"
}

cmd_destroy() {
    require_systemd
    warn "This permanently deletes every container, the network and the volumes:"
    warn "  $VOL_HTML  $VOL_DB  $VOL_REDIS  $VOL_CADDY"
    warn "The database and config.php will be gone. The user files in"
    warn "  $(data_path)"
    warn "are NOT deleted (they are a plain host directory)."
    printf '\nType %sDELETE%s to confirm: ' "$C_BOLD" "$C_RESET"
    local answer=""
    read -r answer || true
    [ "$answer" = "DELETE" ] || die "aborted; nothing was deleted."

    step "Removing the services and their volumes"
    stop_stack
    remove_containers
    remove_volumes "$VOL_HTML" "$VOL_DB" "$VOL_REDIS" "$VOL_CADDY"
    # Stop the (one-shot) network unit first so systemd forgets it is "active".
    sctl stop nextcloud-network.service 2>/dev/null || true
    podman network rm -f "$NETWORK_NAME" >/dev/null 2>&1 || true
    ! podman network exists "$NETWORK_NAME" 2>/dev/null || die "network $NETWORK_NAME could not be removed."
    ok "destroyed (unit files stay installed; ./setup.sh up recreates everything)"
}

# Print the usage block. It is read out of the file's own leading comment
# block rather than hard-coded line numbers, so editing the header can never
# make `help` print the wrong thing.
cmd_help() {
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$SELF"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

main() {
    local command="${1:-up}"
    [ "$#" -gt 0 ] && shift || true

    case "$command" in
        up|start)          cmd_up ;;
        install)           cmd_install ;;
        down|stop)         cmd_down ;;
        restart)           cmd_restart ;;
        status|ps)         cmd_status ;;
        logs)              cmd_logs "$@" ;;
        occ)               cmd_occ "$@" ;;
        creds|password)    cmd_creds ;;
        backup)            cmd_backup "$@" ;;
        restore)           cmd_restore "$@" ;;
        destroy)           cmd_destroy ;;
        uninstall)         cmd_uninstall ;;
        help|-h|--help)    cmd_help ;;
        *)                 die "unknown command '$command'. Run: ./setup.sh help" ;;
    esac
}

# Run only when executed, not when sourced (tests source this file to unit-test
# its functions).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
