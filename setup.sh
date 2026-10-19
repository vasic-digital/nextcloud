#!/usr/bin/env bash
# ===========================================================================
#  Nextcloud on Podman — local-network setup, no domain, no public exposure.
#
#  Usage:  ./setup.sh [command]
#
#    up          (default) create .env if missing, start the stack, wait for
#                the web UI to answer, then print the access URLs
#    down        stop and remove the containers (volumes are kept)
#    restart     recreate the containers to pick up .env / compose.yaml edits
#    status      show container state, published ports and volume sizes
#    logs [svc]  follow logs (all services, or one of: app db redis cron)
#    occ ...     run an occ command inside the running app container
#                e.g.  ./setup.sh occ user:add alice
#    creds       print the generated administrator password
#    backup      write a consistent database dump plus data/config tarballs
#    restore [d] replace the current instance with a backup (default: newest);
#                overwrites files, database and config.php  (type RESTORE)
#    destroy     remove containers, network AND every volume  (type DELETE)
#    help        this text
#
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

readonly COMPOSE_FILE="compose.yaml"
readonly ENV_FILE=".env"
readonly ENV_EXAMPLE=".env.example"

readonly APP_CONTAINER="nextcloud-app"
readonly CRON_CONTAINER="nextcloud-cron"
readonly DB_CONTAINER="nextcloud-db"
readonly PROJECT_NAME="nextcloud"

# Explicit volume names, matching the `name:` keys in compose.yaml. They are
# spelled out rather than derived so backup/restore keep working even if the
# compose project name ever changes.
readonly VOL_HTML="nextcloud-html"
readonly VOL_DATA="nextcloud-data"
readonly VOL_DB="nextcloud-db"
readonly VOL_REDIS="nextcloud-redis"

# Small image used to move files in and out of volumes. The Nextcloud image
# would work too, but this one is a few megabytes instead of a gigabyte.
readonly HELPER_IMAGE="docker.io/library/alpine:3"

# Seconds to wait for the web interface before giving up.
readonly STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"

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

COMPOSE=()

detect_compose() {
    require_cmd podman
    if command -v podman-compose >/dev/null 2>&1; then
        COMPOSE=(podman-compose -f "$COMPOSE_FILE")
    elif podman compose version >/dev/null 2>&1; then
        COMPOSE=(podman compose -f "$COMPOSE_FILE")
    else
        die "Neither 'podman-compose' nor 'podman compose' is available. Install podman-compose."
    fi
}

compose() { "${COMPOSE[@]}" "$@"; }

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

    umask 077
    sed \
        -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" \
        -e "s|^DB_ROOT_PASSWORD=.*|DB_ROOT_PASSWORD=${db_root}|" \
        -e "s|^NEXTCLOUD_ADMIN_USER=.*|NEXTCLOUD_ADMIN_USER=${admin_user}|" \
        -e "s|^NEXTCLOUD_ADMIN_PASSWORD=.*|NEXTCLOUD_ADMIN_PASSWORD=${admin_pass}|" \
        -e "s|^NEXTCLOUD_TRUSTED_DOMAINS=.*|NEXTCLOUD_TRUSTED_DOMAINS=${trusted}|" \
        -e "s|^NEXTCLOUD_OVERWRITE_CLI_URL=.*|NEXTCLOUD_OVERWRITE_CLI_URL=http://${host}:8080|" \
        -e "s|^TZ=.*|TZ=${tz}|" \
        "$ENV_EXAMPLE" > "$ENV_FILE"

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
        have="$(openssl x509 -noout -ext subjectAltName -in "$TLS_DIR/site.crt" 2>/dev/null)"
        local missing=0 token
        for token in ${san//,/ }; do
            # openssl prints IP SANs as "IP Address:x".
            case "$have" in *"${token/IP:/IP Address:}"*) ;; *) missing=1 ;; esac
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
# Preflight
# ---------------------------------------------------------------------------

preflight() {
    step "Preflight checks"

    detect_compose
    ok "$(podman --version)"

    if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        ok "rootless podman"
    else
        warn "running rootful podman — fine, but rootless is the safer default"
    fi

    local port bind
    port="$(env_get NEXTCLOUD_PORT)"; port="${port:-8080}"
    bind="$(env_get NEXTCLOUD_BIND)"; bind="${bind:-0.0.0.0}"

    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        die "NEXTCLOUD_PORT='$port' is not a valid TCP port."
    fi

    # Is something already listening on that host port?
    if command -v ss >/dev/null 2>&1; then
        if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
            # Our own stack may legitimately hold it.
            if ! podman ps --format '{{.Ports}}' | grep -q ":${port}->"; then
                warn "port ${port} is already in use by another process:"
                ss -ltnp "sport = :${port}" 2>/dev/null | tail -n +1 | sed 's/^/     /' >&2
                die "free it, or set NEXTCLOUD_PORT in $ENV_FILE to something else."
            fi
        fi
    fi
    ok "host port ${port} available (bind ${bind})"

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

# Probe http://127.0.0.1:$port/status.php until it reports an installed
# instance. Uses curl when available, otherwise a bash /dev/tcp request.
probe_status() {
    local port="$1" url="http://127.0.0.1:${port}/status.php" body=""

    if command -v curl >/dev/null 2>&1; then
        body="$(curl -fsS --max-time 10 --ipv4 "$url" 2>/dev/null || true)"
    else
        local host=127.0.0.1
        exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null || return 1
        printf 'GET /status.php HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$host" >&3
        body="$(cat <&3 2>/dev/null || true)"
        exec 3<&- 3>&-
    fi

    printf '%s' "$body" | grep -q '"installed": *true'
}

wait_for_web() {
    local port elapsed=0 interval=5
    port="$(env_get NEXTCLOUD_PORT)"; port="${port:-8080}"

    step "Waiting for Nextcloud to finish installing (up to ${STARTUP_TIMEOUT}s)"
    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        if probe_status "$port"; then
            ok "web interface is up and reported as installed (after ${elapsed}s)"
            return 0
        fi

        # Fail fast instead of waiting out the timeout if the app container died.
        if ! podman container exists "$APP_CONTAINER" 2>/dev/null; then
            die "container $APP_CONTAINER no longer exists. Check: ./setup.sh logs app"
        fi
        if [ "$(podman inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2>/dev/null)" != "true" ]; then
            warn "the app container is not running. Last 30 log lines:"
            podman logs --tail 30 "$APP_CONTAINER" 2>&1 | sed 's/^/     /' >&2
            die "startup aborted — see the log excerpt above."
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
# Both directions run a throwaway alpine container with the target volume
# mounted, because the volumes are owned by uid 33 and the host user cannot
# (and should not) write into them directly.

# Wipe a whole volume and unpack an archive that was created with
# `tar -C <parent> <dir>`, i.e. whose entries all carry one leading directory
# that has to be stripped. Ownership is preserved because the helper runs as
# root inside the container.
volume_restore() {
    local archive="$1" backup_dir="$2"

    # Restore user data from the host path specified in .env.
    local host_data_path
    host_data_path="$(env_get DATA_HOST_PATH)"; host_data_path="${host_data_path:-${DATA_HOST_PATH:-}}"
    if [ -z "$host_data_path" ] || [ ! -d "$host_data_path" ]; then
        die "DATA_HOST_PATH not set or directory does not exist: $host_data_path"
    fi

    podman run --rm \
        -v "${host_data_path}:/target:Z" \
        -v "${backup_dir}:/backup:Z" \
        "$HELPER_IMAGE" \
        sh -c "rm -rf /target/* /target/.[!.]* 2>/dev/null || true
               tar xzf /backup/${archive} -C /target --strip-components=1"
}

# Replace a single sub-directory inside a volume, keeping the archive's own
# top-level name. Used for /var/www/html/config, which lives in the html volume
# alongside the program files we must not touch.
volume_restore_subdir() {
    local volume="$1" subdir="$2" archive="$3" backup_dir="$4"

    podman run --rm \
        -v "${volume}:/target" \
        -v "${backup_dir}:/backup:Z" \
        "$HELPER_IMAGE" \
        sh -c "rm -rf /target/${subdir}
               tar xzf /backup/${archive} -C /target"
}

# Capture a whole volume, storing it as <dir>/<name>.tar.gz.
volume_backup() {
    local volume="$1" name="$2" backup_dir="$3"

    podman run --rm \
        -v "${volume}:/source:ro" \
        -v "${backup_dir}:/backup:Z" \
        "$HELPER_IMAGE" \
        tar czf "/backup/${name}.tar.gz" -C /source .
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

print_access_info() {
    local port bind lan_ip host
    port="$(env_get NEXTCLOUD_PORT)"; port="${port:-8080}"
    bind="$(env_get NEXTCLOUD_BIND)"; bind="${bind:-0.0.0.0}"
    lan_ip="$(detect_lan_ip)"
    host="$(hostname 2>/dev/null || echo localhost)"

    printf '\n%s%s  Nextcloud is ready%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"

    if [ "$bind" = "127.0.0.1" ] || [ "$bind" = "localhost" ]; then
        printf '  On this machine   %shttp://localhost:%s%s\n' "$C_BLUE" "$port" "$C_RESET"
    else
        printf '  On this machine   %shttp://localhost:%s%s\n' "$C_BLUE" "$port" "$C_RESET"
        printf '  From the LAN      %shttp://%s:%s%s\n' "$C_BLUE" "${lan_ip:-<host-lan-ip>}" "$port" "$C_RESET"
        [ -n "$host" ] && printf '  By host name      %shttp://%s:%s%s\n' "$C_BLUE" "$host" "$port" "$C_RESET"
    fi

    printf '\n  Administrator     %s\n' "$(env_get NEXTCLOUD_ADMIN_USER)"
    printf '  Password          %s\n' "$(env_get NEXTCLOUD_ADMIN_PASSWORD)"
    printf '  Credentials file  %s\n\n' "$PROJECT_DIR/$ENV_FILE"

    printf '  %sKeep this password: it is stored in .env and nowhere else.%s\n\n' "$C_DIM" "$C_RESET"

    printf '  Useful next steps\n'
    printf '    ./setup.sh occ status\n'
    printf '    ./setup.sh logs app\n'
    printf '    ./setup.sh down\n\n'
}

cmd_up() {
    ensure_env
    preflight

    step "Starting the stack"
    # --no-build is not needed; nothing here builds. podman-compose is quiet by
    # default, so we let its output through unfiltered.
    compose up -d

    wait_for_web
    print_access_info
}

cmd_down() {
    detect_compose
    step "Stopping the stack (volumes are preserved)"
    compose down
    ok "stopped. Data is still in nextcloud-html / nextcloud-data / nextcloud-db / nextcloud-redis"
}

cmd_restart() {
    detect_compose
    step "Recreating containers to pick up configuration changes"
    ensure_tls
    compose down
    compose up -d
    wait_for_web
    print_access_info
}

cmd_status() {
    detect_compose
    step "Containers"
    podman ps -a --filter "name=^nextcloud-" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

    step "Volumes"
    podman volume ls --filter "name=^nextcloud-" --format 'table {{.Name}}\t{{.Driver}}' || true

    step "Disk usage per volume"
    local vol mount
    for vol in nextcloud-html nextcloud-data nextcloud-db nextcloud-redis; do
        podman volume exists "$vol" 2>/dev/null || continue
        mount="$(podman volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
        if [ -n "$mount" ] && [ -d "$mount" ]; then
            printf '  %-20s %s\n' "$vol" "$(du -sh "$mount" 2>/dev/null | cut -f1)"
        fi
    done

    step "Health"
    local port
    port="$(env_get NEXTCLOUD_PORT)"; port="${port:-8080}"
    if probe_status "$port"; then
        ok "Nextcloud answers on port ${port} and reports itself installed"
    else
        warn "Nextcloud did not answer correctly on port ${port}"
    fi
}

cmd_logs() {
    detect_compose
    local service="${1:-}"
    if [ -z "$service" ]; then
        compose logs -f --tail=100
    else
        case "$service" in
            app|db|redis|cron) compose logs -f --tail=100 "$service" ;;
            *) die "unknown service '$service' (expected: app, db, redis, cron)" ;;
        esac
    fi
}

cmd_occ() {
    require_cmd podman
    if ! podman container exists "$APP_CONTAINER" 2>/dev/null; then
        die "$APP_CONTAINER is not running. Start it with: ./setup.sh up"
    fi
    podman exec -u www-data "$APP_CONTAINER" php /var/www/html/occ "$@"
}

cmd_creds() {
    [ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist. Run ./setup.sh up first."
    printf 'Administrator  %s\n' "$(env_get NEXTCLOUD_ADMIN_USER)"
    printf 'Password       %s\n' "$(env_get NEXTCLOUD_ADMIN_PASSWORD)"
}

cmd_backup() {
    require_cmd podman
    local stamp dir dbname archive
    archive="data"
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="$PROJECT_DIR/backups/$stamp"
    dbname="$(env_get DB_NAME)"; dbname="${dbname:-nextcloud}"
    mkdir -p "$dir"
    chmod 0700 "$dir"

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
    host_data_path="$(env_get DATA_HOST_PATH)"; host_data_path="${host_data_path:-${DATA_HOST_PATH:-}}"
    if [ -z "$host_data_path" ] || [ ! -d "$host_data_path" ]; then
        warn "DATA_HOST_PATH not set or directory does not exist; skipping data backup"
    else
        podman run --rm \
            -v "${host_data_path}:/source:Z" \
            -v "$dir:/backup:Z" \
            "$HELPER_IMAGE" \
            tar czf "/backup/${archive}.tar.gz" -C /source .
        ok "data.tar.gz ($(du -h "$dir/data.tar.gz" | cut -f1))"
    fi

    step "Archiving config.php"
    # config.php holds the instanceid, secret and passwordsalt. Without it a
    # restored database is an orphan: the instance id would no longer match and
    # Nextcloud would refuse to log anyone in. It is tiny, so back it up too.
    # It lives inside the html volume, so grab just that one directory.
    podman run --rm \
        -v "${VOL_HTML}:/source:ro" \
        -v "$dir:/backup:Z" \
        "$HELPER_IMAGE" \
        tar czf /backup/config.tar.gz -C /source config
    ok "config.tar.gz ($(du -h "$dir/config.tar.gz" | cut -f1))"

    step "Copying configuration"
    cp -- "$ENV_FILE" "$dir/env.backup"
    cp -- "$COMPOSE_FILE" "$dir/compose.yaml.backup"
    chmod 0600 "$dir/env.backup"

    printf '\n%sBackup complete:%s %s\n' "$C_GREEN" "$C_RESET" "$dir"
    printf 'Restore it with:  ./setup.sh restore %s\n\n' "$stamp"
}

# Newest directory under backups/, or die trying.
newest_backup() {
    local dir
    dir="$(find backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | tail -1)"
    [ -n "$dir" ] || die "no backups found in $PROJECT_DIR/backups — run ./setup.sh backup first."
    printf '%s' "$dir"
}

cmd_restore() {
    require_cmd podman
    detect_compose
    # `compose up` below also starts caddy, whose ./tls bind mount must exist.
    ensure_tls

    local backup_dir="${1:-}" dbname answer
    if [ -z "$backup_dir" ]; then
        backup_dir="$(newest_backup)"
    elif [ ! -d "$backup_dir" ] && [ -d "backups/$backup_dir" ]; then
        # Accept the bare timestamp that `backup` prints, not just a path.
        backup_dir="backups/$backup_dir"
    fi
    [ -d "$backup_dir" ] || die "no such backup directory: $backup_dir"
    # Absolute path: it is mounted into a container further down.
    backup_dir="$(cd -- "$backup_dir" && pwd)"

    for f in database.sql.gz data.tar.gz config.tar.gz env.backup; do
        [ -f "$backup_dir/$f" ] || die "$backup_dir is not a complete backup set: $f is missing."
    done

    warn "This REPLACES the current instance — user files, the database and"
    warn "config.php — with the contents of:"
    warn "  $backup_dir"
    warn "The current contents are lost. Take a backup first if you want them."
    printf '\nType %sRESTORE%s to confirm: ' "$C_BOLD" "$C_RESET"
    read -r answer
    [ "$answer" = "RESTORE" ] || die "aborted; nothing was restored."

    step "Restoring $ENV_FILE from the backup"
    # The dump's tables belong to the credentials in this file. Restoring one
    # without the other produces an instance that cannot reach its own database.
    cp -- "$backup_dir/env.backup" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    ok "$ENV_FILE restored (mode 0600)"

    step "Creating volumes and containers from scratch"
    # On a fresh volume this also runs the image's own installer once. That
    # throwaway instance is completely overwritten a moment later; it exists
    # because a named volume is only populated from the image while it is
    # still empty, and we need the program files in place before we can put
    # the backed-up config.php on top.
    compose up -d

    wait_for_db
    wait_for_web

    step "Stopping the web containers while data is written"
    podman stop "$APP_CONTAINER" "$CRON_CONTAINER" >/dev/null 2>&1 || true
    ok "app and cron stopped (database and redis stay up)"

    dbname="$(env_get DB_NAME)"; dbname="${dbname:-nextcloud}"

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

    step "Starting the web containers again"
    compose up -d
    wait_for_web

    step "Verifying the restored instance"
    local instanceid users
    instanceid="$(podman exec -u www-data "$APP_CONTAINER" php /var/www/html/occ config:system:get instanceid 2>/dev/null || echo '?')"
    users="$(podman exec -u www-data "$APP_CONTAINER" php /var/www/html/occ user:list 2>/dev/null | wc -l)"
    ok "instance id   ${instanceid}"
    ok "user accounts ${users}"

    printf '\n%sRestore complete.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf 'Log in with the administrator credentials from the restored backup:\n\n'
    cmd_creds
    printf '\n'
    print_access_info
}

cmd_destroy() {
    detect_compose
    warn "This permanently deletes every container, the network and ALL volumes:"
    warn "  nextcloud-html  nextcloud-data  nextcloud-db  nextcloud-redis"
    warn "User files, the database and config.php will be gone."
    printf '\nType %sDELETE%s to confirm: ' "$C_BOLD" "$C_RESET"
    local answer=""
    read -r answer
    [ "$answer" = "DELETE" ] || die "aborted; nothing was deleted."

    step "Removing the stack and its volumes"
    compose down --volumes
    ok "destroyed"
}

# Print the usage block. It is read out of the file's own leading comment
# block rather than hard-coded line numbers, so editing the header can never
# make `help` print the wrong thing.
cmd_help() {
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

main() {
    local command="${1:-up}"
    [ "$#" -gt 0 ] && shift || true

    case "$command" in
        up|start)          cmd_up ;;
        down|stop)         cmd_down ;;
        restart)           cmd_restart ;;
        status|ps)         cmd_status ;;
        logs)              cmd_logs "$@" ;;
        occ)               cmd_occ "$@" ;;
        creds|password)    cmd_creds ;;
        backup)            cmd_backup ;;
        restore)           cmd_restore "$@" ;;
        destroy)           cmd_destroy ;;
        help|-h|--help)    cmd_help ;;
        *)                 die "unknown command '$command'. Run: ./setup.sh help" ;;
    esac
}

main "$@"
