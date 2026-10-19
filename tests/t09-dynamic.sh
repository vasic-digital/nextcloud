#!/usr/bin/env bash
# ===========================================================================
#  t09-dynamic: function-level tests of setup.sh against throw-away
#  directories and synthetic env files. Proves that nothing is hard-coded:
#  ids, ports, paths, images, subnets and certificates all follow the inputs.
#  The live stack is only READ (podman image/network inspect), never changed.
# ===========================================================================
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

t_begin t09 "dynamic: setup.sh functions with throw-away configuration"

T="$(t_tmpdir)"
HOST_NOW="$(hostname)"
ME_USER="$(id -un)"

# ---- helpers ---------------------------------------------------------------
rand_hex() { openssl rand -hex 24; }

# setkv FILE KEY VALUE: the LAST assignment wins (env_get uses tail -1).
setkv() { printf '%s=%s\n' "$2" "$3" >> "$1"; }

# Base env: .env.example with synthetic secrets and a temp data dir. Never the live .env.
BASE="$T/base.env"
cp .env.example "$BASE"
chmod 0600 "$BASE"
for k in DB_PASSWORD DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD; do setkv "$BASE" "$k" "$(rand_hex)"; done
setkv "$BASE" DATA_HOST_PATH "$T/data"
setkv "$BASE" TRUSTED_PROXIES "203.0.113.0/24"
setkv "$BASE" NEXTCLOUD_TRUSTED_DOMAINS "localhost 127.0.0.1 extra.example"
ALLIDS="APP_UID=4001 APP_GID=4002 DB_UID=4003 DB_GID=4004 REDIS_UID=4005 REDIS_GID=4006"

# mkenv NAME [KEY=VAL ...] -> $T/NAME.env (base + overrides)
mkenv() {
    local name="$1" kv; shift
    cp "$BASE" "$T/$name.env"; chmod 0600 "$T/$name.env"
    for kv in "$@"; do setkv "$T/$name.env" "${kv%%=*}" "${kv#*=}"; done
}

# S ENVFILE 'snippet' -> runs the snippet with setup.sh sourced, everything redirected.
S() {
    local envf="$1" snip="$2"
    NEXTCLOUD_ENV_FILE="$envf" NEXTCLOUD_RUN_DIR="$T/run-s" NEXTCLOUD_QUADLET_DIR="$T/units-s" \
        NEXTCLOUD_NO_RELOAD=1 in_setup "$snip"
}
# rc-only / output + rc capture without tripping the module
S_rc() { local out rc; out="$(S "$@" 2>&1)"; rc=$?; printf '%s' "$out"; return $rc; }

# render NAME [KEY=VAL ...] -> renders into $T/NAME/units, run dir $T/NAME/run
render() {
    local name="$1"; shift
    mkenv "$name" "$@"
    mkdir -p "$T/$name"
    NEXTCLOUD_ENV_FILE="$T/$name.env" NEXTCLOUD_RUN_DIR="$T/$name/run" NEXTCLOUD_QUADLET_DIR="$T/$name/units" \
        NEXTCLOUD_NO_RELOAD=1 in_setup 'require_systemd; render_units'
}
unit() { cat "$T/$1/units/nextcloud-$2.container"; }

QUADLET_BIN_T=""
for _c in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$_c" ] && { QUADLET_BIN_T="$_c"; break; }; done
dry() { QUADLET_UNIT_DIRS="$1" "$QUADLET_BIN_T" -dryrun -user >/dev/null 2>&1; }

# ===========================================================================
# 1. Identity discovery vs. independent ground truth
# ===========================================================================
mkenv plain
IMG_APP="$(S "$T/plain.env" 'image_of nextcloud')"
IMG_DB="$(S "$T/plain.env" 'image_of db')"
IMG_REDIS="$(S "$T/plain.env" 'image_of redis')"
LIVE="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

# Account names as documented in the LIVE rendered units: "(<name>, uid:gid 33:33" / "(<name>, 999:1000)".
acct_of() { sed -n 's/^#.*(\([a-z_][a-z0-9_-]*\), \(uid:gid \)\{0,1\}[0-9]*:[0-9]*.*/\1/p' "$LIVE/nextcloud-$1.container" | head -1; }
truth() {  # truth IMAGE ACCOUNT -> "uid gid", via a plain `id` inside the image
    local o
    o="$(podman run --rm --pull=never --entrypoint sh "$1" -c "id -u '$2'; id -g '$2'" 2>/dev/null)" || return 1
    printf '%s' "$(printf '%s\n' "$o" | paste -sd' ')"
}
for spec in "APP|app|$IMG_APP|nextcloud" "DB|db|$IMG_DB|db" "REDIS|redis|$IMG_REDIS|redis"; do
    IFS='|' read -r P svc img key <<<"$spec"
    acct="$(acct_of "$svc")"
    if [ -z "$acct" ]; then t_fail "[$P] account name parsed from live unit nextcloud-$svc.container" "no '(name, uid:gid ...)' comment found"; continue; fi
    gt="$(truth "$img" "$acct")"
    t_match "[$P] ground truth from the image is numeric (podman run id -u/-g $acct)" '^[0-9]+ [0-9]+$' "$gt"
    got="$(S "$T/plain.env" "service_ids $P $key; echo \"\$${P}_RUN_USER \$${P}_UID \$${P}_GID\"")"
    t_eq "[$P] service_ids discovery equals ground truth (account $acct)" "$acct $gt" "$got"
    # The live unit must carry exactly those ids.
    t_match "[$P] live unit UserNS= carries the discovered ids" "^UserNS=keep-id:uid=${gt% *},gid=${gt#* }\$" \
        "$(grep -h '^UserNS=' "$LIVE/nextcloud-$svc.container")"
done
t_ne "negative control: discovery is not a constant (www-data/mysql ids differ from a bogus value)" "4242 4343" "$(S "$T/plain.env" 'service_ids APP nextcloud; echo "$APP_UID $APP_GID"')"

# ===========================================================================
# 2. Override precedence
# ===========================================================================
# 2a. APP_UID/APP_GID override flows into app AND cron; db/redis keep discovered ids.
GT_DB="$(S "$T/plain.env" 'service_ids DB db; echo "$DB_UID $DB_GID"')"
GT_REDIS="$(S "$T/plain.env" 'service_ids REDIS redis; echo "$REDIS_UID $REDIS_GID"')"
t_check "render with APP_UID=4242 APP_GID=4343 succeeds" render ovr APP_UID=4242 APP_GID=4343
for svc in app cron; do
    t_match "UserNS=keep-id:uid=4242,gid=4343 in nextcloud-$svc" '(^|'$'\n'')UserNS=keep-id:uid=4242,gid=4343('$'\n''|$)' "$(unit ovr $svc)"
done
t_match "db unit keeps its discovered ids" "UserNS=keep-id:uid=${GT_DB% *},gid=${GT_DB#* }" "$(unit ovr db)"
t_match "redis unit keeps its discovered ids" "UserNS=keep-id:uid=${GT_REDIS% *},gid=${GT_REDIS#* }" "$(unit ovr redis)"
t_nomatch "negative control: db/redis do NOT pick up the app override" 'uid=4242' "$(unit ovr db)$(unit ovr redis)"
t_check "quadlet -dryrun passes for the override variant" dry "$T/ovr/units"

# 2b. Bogus account name without ids -> clear failure.
mkenv bogus APP_RUN_USER=doesnotexist
_out="$(S_rc "$T/bogus.env" 'service_ids APP nextcloud' )"; _rc=$?
t_ne "bogus APP_RUN_USER without ids: service_ids exits non-zero" 0 "$_rc"
t_match "bogus APP_RUN_USER: message names the account" "doesnotexist" "$_out"
t_match "bogus APP_RUN_USER: message tells how to fix (APP_RUN_USER / APP_UID and APP_GID)" 'APP_RUN_USER.*APP_UID.*APP_GID' "$_out"

# 2c. Both ids set: no image lookup at all (an unpullable image must not matter).
mkenv noimg APP_RUN_USER=doesnotexist APP_UID=4242 APP_GID=4343 NEXTCLOUD_IMAGE=localhost/t09-no-such-image:0
_out="$(S_rc "$T/noimg.env" 'service_ids APP nextcloud; echo "$APP_RUN_USER $APP_UID $APP_GID"')"; _rc=$?
t_eq "both ids set: service_ids succeeds without touching the (nonexistent) image" "0" "$_rc"
t_eq "both ids set: values come straight from the env file" "doesnotexist 4242 4343" "$_out"
# Negative control: the same image WITHOUT ids must fail, proving the lookup would have been needed.
mkenv noimg2 NEXTCLOUD_IMAGE=localhost/t09-no-such-image:0
_out="$(S_rc "$T/noimg2.env" 'service_ids APP nextcloud' 2>&1)"; _rc=$?
t_ne "negative control: without ids the nonexistent image makes service_ids fail" 0 "$_rc"

# 2d. Only UID set: GID is discovered, UID is kept.
GT_APP="$(S "$T/plain.env" 'service_ids APP nextcloud; echo "$APP_UID $APP_GID"')"
mkenv uidonly APP_UID=4242
t_eq "only APP_UID set: uid from env, gid from the image" "4242 ${GT_APP#* }" "$(S "$T/uidonly.env" 'service_ids APP nextcloud; echo "$APP_UID $APP_GID"')"
mkenv unknown
t_check_not "service_ids rejects an unknown prefix" S "$T/unknown.env" 'service_ids NOPE nextcloud'

# ===========================================================================
# 3. Rendering variants
# ===========================================================================
DP="$T/data-variant"
t_check "render variant: ports, bind, data path, images" render var \
    $ALLIDS NEXTCLOUD_PORT=18080 NEXTCLOUD_HTTPS_PORT=18443 NEXTCLOUD_BIND=127.0.0.1 DATA_HOST_PATH="$DP" \
    NEXTCLOUD_IMAGE=docker.io/library/nextcloud:35-apache-x DB_IMAGE=docker.io/library/mariadb:11-x \
    REDIS_IMAGE=docker.io/library/redis:7-x CADDY_IMAGE=localhost/caddy-x:9
t_match "app PublishPort is exactly 127.0.0.1:18080:80" $'(^|\n)PublishPort=127\\.0\\.0\\.1:18080:80(\n|$)' "$(unit var app)"
t_match "caddy PublishPort tcp is exactly 127.0.0.1:18443:443/tcp" $'(^|\n)PublishPort=127\\.0\\.0\\.1:18443:443/tcp(\n|$)' "$(unit var caddy)"
t_match "caddy PublishPort udp is exactly 127.0.0.1:18443:443/udp" $'(^|\n)PublishPort=127\\.0\\.0\\.1:18443:443/udp(\n|$)' "$(unit var caddy)"
t_eq "caddy publishes exactly two ports" 2 "$(grep -c '^PublishPort=' "$T/var/units/nextcloud-caddy.container")"
t_eq "app publishes exactly one port" 1 "$(grep -c '^PublishPort=' "$T/var/units/nextcloud-app.container")"
t_eq "db and redis publish nothing" 0 "$(cat "$T"/var/units/nextcloud-{db,redis}.container | grep -c '^PublishPort=')"
t_nomatch "negative control: defaults leaked into the variant (no 8080/52443 mapping)" ':(8080|52443):' "$(grep -h PublishPort "$T"/var/units/*)"
for svc in app cron; do
    t_match "Volume= in $svc contains the data path" "(^|"$'\n'")Volume=${DP}:/var/www/html/data(\$|"$'\n'")" "$(unit var $svc)"
done
for svc in app cron; do
    t_eq "Image= in $svc is the override" "Image=docker.io/library/nextcloud:35-apache-x" "$(grep '^Image=' "$T/var/units/nextcloud-$svc.container")"
done
t_eq "app and cron Image= lines are identical (no drift)" "$(grep -h '^Image=' "$T/var/units/nextcloud-app.container")" "$(grep -h '^Image=' "$T/var/units/nextcloud-cron.container")"
t_eq "db Image= override" "Image=docker.io/library/mariadb:11-x" "$(grep '^Image=' "$T/var/units/nextcloud-db.container")"
t_eq "redis Image= override" "Image=docker.io/library/redis:7-x" "$(grep '^Image=' "$T/var/units/nextcloud-redis.container")"
t_eq "caddy Image= override" "Image=localhost/caddy-x:9" "$(grep '^Image=' "$T/var/units/nextcloud-caddy.container")"
t_match "all-ids variant: app uses 4001:4002" 'UserNS=keep-id:uid=4001,gid=4002' "$(unit var app)"
t_match "all-ids variant: cron uses 4001:4002" 'UserNS=keep-id:uid=4001,gid=4002' "$(unit var cron)"
t_match "all-ids variant: db uses 4003:4004" 'UserNS=keep-id:uid=4003,gid=4004' "$(unit var db)"
t_match "all-ids variant: redis uses 4005:4006" 'UserNS=keep-id:uid=4005,gid=4006' "$(unit var redis)"
t_match "the host user in the unit comments comes from id -un" "host user \`${ME_USER}\`" "$(unit var app)"
t_match "EnvironmentFile points into the redirected run dir" "^EnvironmentFile=$T/var/run/app.env" "$(grep '^EnvironmentFile=' "$T/var/units/nextcloud-app.container")"
t_match "project dir in Documentation= is this checkout" "file://${T_ROOT}/README.md" "$(unit var app)"
if [ -n "$QUADLET_BIN_T" ]; then
    t_check "quadlet -dryrun passes for the ports/images/path variant" dry "$T/var/units"
else
    t_skip "quadlet -dryrun" "quadlet generator not found"
fi

# Defaults come from the DEFAULT_* constants, not from literals in the render path.
DEF_HTTP="$(S "$T/plain.env" 'echo "$DEFAULT_HTTP_PORT"')"
DEF_HTTPS="$(S "$T/plain.env" 'echo "$DEFAULT_HTTPS_PORT"')"
DEF_BIND="$(S "$T/plain.env" 'echo "$DEFAULT_BIND"')"
t_check "render with no port/bind/image overrides" render defl $ALLIDS NEXTCLOUD_PORT= NEXTCLOUD_HTTPS_PORT= NEXTCLOUD_BIND= NEXTCLOUD_IMAGE= DB_IMAGE= REDIS_IMAGE= CADDY_IMAGE= DATA_HOST_PATH=
t_match "defaults: app publishes DEFAULT_BIND:DEFAULT_HTTP_PORT" "PublishPort=${DEF_BIND}:${DEF_HTTP}:80" "$(unit defl app)"
t_match "defaults: caddy publishes DEFAULT_HTTPS_PORT" "PublishPort=${DEF_BIND}:${DEF_HTTPS}:443/tcp" "$(unit defl caddy)"
t_match "defaults: data dir defaults to <project>/data" "Volume=${T_ROOT}/data:/var/www/html/data" "$(unit defl app)"
t_eq "defaults: app Image= is DEFAULT_NEXTCLOUD_IMAGE" "Image=$(S "$T/plain.env" 'echo "$DEFAULT_NEXTCLOUD_IMAGE"')" "$(grep '^Image=' "$T/defl/units/nextcloud-app.container")"

# Hostile data path (sed metacharacters) must round-trip through render_units.
HP="$T/we&ird|path"
t_check "render with sed metacharacters in DATA_HOST_PATH" render hostile $ALLIDS DATA_HOST_PATH="$HP"
t_match "hostile path appears verbatim in the Volume= line" "Volume=$T/we&ird\\|path:/var/www/html/data" "$(unit hostile app)"

# ===========================================================================
# 4. data_path
# ===========================================================================
mkenv relpath DATA_HOST_PATH=relative/dir
_out="$(S_rc "$T/relpath.env" 'data_path')"; _rc=$?
t_ne "relative DATA_HOST_PATH is rejected (non-zero exit)" 0 "$_rc"
t_match "relative DATA_HOST_PATH: message says 'absolute'" 'absolute' "$_out"
t_match "relative DATA_HOST_PATH: message echoes the offending value" 'relative/dir' "$_out"
mkenv nopath DATA_HOST_PATH=
_out="$(S_rc "$T/nopath.env" 'data_path')"
t_eq "unset DATA_HOST_PATH defaults to <project>/data" "${T_ROOT}/data" "$_out"
t_match "default data path is absolute" '^/' "$_out"
mkenv abspath DATA_HOST_PATH=/some/abs/path
t_eq "absolute DATA_HOST_PATH is returned verbatim" "/some/abs/path" "$(S "$T/abspath.env" 'data_path')"

# ===========================================================================
# 5. env_get / env_or / env_need / image_of / sed_esc
# ===========================================================================
cat > "$T/kv.env" <<'EOF'
T9_PLAIN=fromfile
T9_DUP=first
T9_DUP=second
T9_EMPTY=
T9_EQ=a=b=c
T9_SPACE=one two  three
T9_PREFIXED=nope
T9_PREFIX=yes
EOF
export T9_PLAIN=fromenv T9_ENVONLY=fromenv
t_eq "env_get reads the file" fromfile "$(S "$T/kv.env" 'env_get T9_PLAIN')"
t_eq "env_get: the last duplicate wins" second "$(S "$T/kv.env" 'env_get T9_DUP')"
t_eq "env_get keeps '=' inside values" "a=b=c" "$(S "$T/kv.env" 'env_get T9_EQ')"
t_eq "env_get keeps inner spaces" "one two  three" "$(S "$T/kv.env" 'env_get T9_SPACE')"
t_eq "env_get is anchored (T9_PREFIX does not match T9_PREFIXED)" yes "$(S "$T/kv.env" 'env_get T9_PREFIX')"
t_eq "env_get ignores the process environment (file is the single source)" "" "$(S "$T/kv.env" 'env_get T9_ENVONLY')"
t_eq "env_or: file value beats the default" fromfile "$(S "$T/kv.env" 'env_or T9_PLAIN dflt')"
t_eq "env_or: missing key -> default" dflt "$(S "$T/kv.env" 'env_or T9_MISSING dflt')"
t_eq "env_or: empty value -> default" dflt "$(S "$T/kv.env" 'env_or T9_EMPTY dflt')"
t_eq "env_or: process env does not leak in (missing key -> default)" dflt "$(S "$T/kv.env" 'env_or T9_ENVONLY dflt')"
t_eq "env_get on a missing env file prints nothing and succeeds" "" "$(S "$T/does-not-exist.env" 'env_get ANYTHING; echo -n')"
t_eq "env_need returns the value" fromfile "$(S "$T/kv.env" 'env_need T9_PLAIN')"
_out="$(S_rc "$T/kv.env" 'env_need T9_MISSING')"; _rc=$?
t_ne "env_need on a missing key exits non-zero" 0 "$_rc"
t_match "env_need names the missing key" 'T9_MISSING is not set' "$_out"
_out="$(S_rc "$T/kv.env" 'env_need T9_EMPTY')"; _rc=$?
t_ne "env_need on an empty key exits non-zero" 0 "$_rc"
unset T9_PLAIN T9_ENVONLY

# image_of
for kind in nextcloud db redis caddy helper; do
    var="DEFAULT_$(printf '%s' "$kind" | tr a-z A-Z)_IMAGE"
    t_eq "image_of $kind -> $var when nothing is set" "$(S "$T/plain.env" "echo \"\$$var\"")" "$(S "$T/plain.env" "image_of $kind")"
done
mkenv imgs NEXTCLOUD_IMAGE=reg.example/nc:1 DB_IMAGE=reg.example/db:2 REDIS_IMAGE=reg.example/rd:3 CADDY_IMAGE=reg.example/cd:4 HELPER_IMAGE=reg.example/hp:5
for pair in nextcloud:nc:1 db:db:2 redis:rd:3 caddy:cd:4 helper:hp:5; do
    kind="${pair%%:*}"; rest="${pair#*:}"
    t_eq "image_of $kind honours the env file" "reg.example/${rest}" "$(S "$T/imgs.env" "image_of $kind")"
done
_out="$(S_rc "$T/plain.env" 'image_of bogus')"; _rc=$?
t_ne "image_of with an unknown kind fails" 0 "$_rc"
t_match "image_of unknown kind: message names it" 'bogus' "$_out"
t_eq "app_user default" "$(S "$T/plain.env" 'echo "$DEFAULT_APP_RUN_USER"')" "$(S "$T/plain.env" 'app_user')"
mkenv au APP_RUN_USER=someone
t_eq "app_user honours APP_RUN_USER" someone "$(S "$T/au.env" 'app_user')"

# sed_esc round-trips hostile strings through a real sed substitution.
HOSTILE=('a|b&c\d' '&&&' '\\\' '|||' 'x\1y' 'a/b/c' 'tab	here' '$HOME `id` $(id)' "it's" 'trail\')
for s in "${HOSTILE[@]}"; do
    # pass the string safely as $1 through a wrapper instead of interpolating it
    rt="$(NEXTCLOUD_ENV_FILE="$T/plain.env" bash -c 'set -Eeuo pipefail; source ./setup.sh; printf "%s\n" PLACEHOLDER | sed -e "s|PLACEHOLDER|$(sed_esc "$1")|"' _ "$s")"
    t_eq "sed_esc round-trips: $(printf '%s' "$s" | head -c 30)" "$s" "$rt"
done
_raw="$(printf 'PLACEHOLDER\n' | sed -e "s|PLACEHOLDER|a|b&c\\d|" 2>&1 || true)"
t_ne "negative control: WITHOUT sed_esc the hostile string does not round-trip" 'a|b&c\d' "$_raw"

# ===========================================================================
# 6. probe_host
# ===========================================================================
probe() { mkenv probe NEXTCLOUD_BIND="$1"; S "$T/probe.env" 'probe_host'; }
t_eq "probe_host: 0.0.0.0 -> 127.0.0.1" 127.0.0.1 "$(probe 0.0.0.0)"
t_eq "probe_host: :: -> 127.0.0.1" 127.0.0.1 "$(probe '::')"
t_eq "probe_host: [::] -> 127.0.0.1" 127.0.0.1 "$(probe '[::]')"
t_eq "probe_host: 192.0.2.77 -> 192.0.2.77" 192.0.2.77 "$(probe 192.0.2.77)"
t_eq "probe_host: 127.0.0.1 -> 127.0.0.1" 127.0.0.1 "$(probe 127.0.0.1)"
t_eq "probe_host: unset -> DEFAULT_BIND mapped to loopback" 127.0.0.1 "$(probe '')"
t_ne "negative control: probe_host does not echo the wildcard" 0.0.0.0 "$(probe 0.0.0.0)"

# ===========================================================================
# 7. write_env_files
# ===========================================================================
NET_TRUTH="$(podman network inspect nextcloud-net 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(s.get("subnet") or s.get("Subnet") for n in d for s in (n.get("subnets") or n.get("Subnets") or [])))' 2>/dev/null)"
wef() {  # wef NAME [KEY=VAL..]: run write_env_files with run dir $T/NAME/run (umask 022 on purpose)
    local name="$1"; shift
    mkenv "wef-$name" "$@"; mkdir -p "$T/wef-$name"
    NEXTCLOUD_ENV_FILE="$T/wef-$name.env" NEXTCLOUD_RUN_DIR="$T/wef-$name/run" \
        in_setup 'umask 022; write_env_files'
}
envval() { sed -n "s/^$2=//p" "$1" | tail -1; }

t_check "write_env_files with TRUSTED_PROXIES set" wef set TRUSTED_PROXIES=198.51.100.0/24,203.0.113.7
R="$T/wef-set/run"
t_eq "TRUSTED_PROXIES in app.env is written verbatim" "198.51.100.0/24,203.0.113.7" "$(envval "$R/app.env" TRUSTED_PROXIES)"

if [ -n "$NET_TRUTH" ]; then
    t_check "write_env_files with empty TRUSTED_PROXIES" wef empty TRUSTED_PROXIES=
    t_eq "empty TRUSTED_PROXIES -> subnet(s) of the live nextcloud-net network" "$NET_TRUTH" "$(envval "$T/wef-empty/run/app.env" TRUSTED_PROXIES)"
    t_match "the discovered proxy value looks like a CIDR" '^[0-9a-f.:]+/[0-9]+' "$(envval "$T/wef-empty/run/app.env" TRUSTED_PROXIES)"
    t_ne "negative control: discovered value differs from the explicit one" "198.51.100.0/24,203.0.113.7" "$(envval "$T/wef-empty/run/app.env" TRUSTED_PROXIES)"
else
    t_skip "TRUSTED_PROXIES from nextcloud-net" "network nextcloud-net does not exist or has no subnet"
fi

for k in DB_PASSWORD DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD; do
    _out="$(wef "cm-$k" "$k=change-me" 2>&1)"; _rc=$?
    t_ne "$k=change-me is refused (non-zero)" 0 "$_rc"
    t_match "$k=change-me: message mentions the placeholder" 'change-me' "$_out"
    t_eq "$k=change-me: nothing was written" 0 "$(ls "$T/wef-cm-$k/run" 2>/dev/null | wc -l)"
done
_out="$(wef missing DB_PASSWORD= 2>&1)"; _rc=$?
t_ne "an empty DB_PASSWORD is refused too" 0 "$_rc"
t_match "empty DB_PASSWORD: message names the key" 'DB_PASSWORD' "$_out"

t_check "write_env_files with custom DB_NAME / DB_USER" wef names DB_NAME=customdb DB_USER=customuser
R="$T/wef-names/run"
t_eq "run dir mode is 700 (even under umask 022)" 700 "$(stat -c %a "$R")"
for f in db.env app.env cron.env caddy.env redis-session.ini; do
    t_eq "$f exists with mode 600" "600" "$(stat -c %a "$R/$f" 2>/dev/null)"
done
DBROOT="$(envval "$T/wef-names.env" DB_ROOT_PASSWORD)"
ADMINPW="$(envval "$T/wef-names.env" NEXTCLOUD_ADMIN_PASSWORD)"
DBPW="$(envval "$T/wef-names.env" DB_PASSWORD)"
t_check_not "least privilege: app.env has no DB_ROOT_PASSWORD key" grep -q 'ROOT_PASSWORD' "$R/app.env"
t_check_not "least privilege: app.env does not contain the root password VALUE" grep -qF -- "$DBROOT" "$R/app.env"
t_check_not "least privilege: db.env has no NEXTCLOUD_ADMIN_PASSWORD key" grep -q 'NEXTCLOUD_ADMIN_PASSWORD' "$R/db.env"
t_check_not "least privilege: db.env does not contain the admin password VALUE" grep -qF -- "$ADMINPW" "$R/db.env"
t_check_not "least privilege: cron.env carries no password" grep -qiE 'pass|secret' "$R/cron.env"
t_check_not "least privilege: caddy.env carries no password" grep -qiE 'pass|secret' "$R/caddy.env"
t_check_not "least privilege: cron.env does not contain any secret value" grep -qF -e "$DBROOT" -e "$ADMINPW" -e "$DBPW" "$R/cron.env"
# Negative controls: the greps above can find these when present.
t_check "negative control: db.env DOES contain MARIADB_ROOT_PASSWORD" grep -q '^MARIADB_ROOT_PASSWORD=' "$R/db.env"
# First-install credentials live in app.env ONLY until the instance is installed
# (otherwise they would sit in the running container's environment forever).
# instance_installed is stubbed so the result does not depend on the live stack.
wef_stub() {  # wef_stub NAME fresh|installed
    local name="$1" rc=0; [ "$2" = fresh ] && rc=1
    mkenv "wef-$name"; mkdir -p "$T/wef-$name"
    NEXTCLOUD_ENV_FILE="$T/wef-$name.env" NEXTCLOUD_RUN_DIR="$T/wef-$name/run" \
        in_setup "instance_installed() { return $rc; }; umask 022; write_env_files"
}
t_check "write_env_files for a FRESH instance (not installed yet)" wef_stub fresh fresh
t_check "fresh: app.env contains NEXTCLOUD_ADMIN_USER (needed by the installer)" grep -q '^NEXTCLOUD_ADMIN_USER=' "$T/wef-fresh/run/app.env"
t_check "fresh: app.env contains NEXTCLOUD_ADMIN_PASSWORD (needed by the installer)" grep -q '^NEXTCLOUD_ADMIN_PASSWORD=' "$T/wef-fresh/run/app.env"
t_check "write_env_files for an INSTALLED instance" wef_stub installed installed
t_check_not "installed: app.env has no NEXTCLOUD_ADMIN_PASSWORD key" grep -q 'NEXTCLOUD_ADMIN_PASSWORD' "$T/wef-installed/run/app.env"
t_check_not "installed: app.env has no NEXTCLOUD_ADMIN_USER key" grep -q 'NEXTCLOUD_ADMIN_USER' "$T/wef-installed/run/app.env"
_apw="$(envval "$T/wef-installed.env" NEXTCLOUD_ADMIN_PASSWORD)"
t_check_not "installed: the admin password VALUE is in none of the env files" grep -rqF -- "$_apw" "$T/wef-installed/run"
t_check "installed: everything else is still written (DB settings, proxies)" grep -q '^MYSQL_HOST=' "$T/wef-installed/run/app.env"
t_eq "app.env MYSQL_PASSWORD equals DB_PASSWORD" "$DBPW" "$(envval "$R/app.env" MYSQL_PASSWORD)"
t_eq "db.env MARIADB_PASSWORD equals DB_PASSWORD" "$DBPW" "$(envval "$R/db.env" MARIADB_PASSWORD)"
t_eq "db.env MARIADB_ROOT_PASSWORD equals DB_ROOT_PASSWORD" "$DBROOT" "$(envval "$R/db.env" MARIADB_ROOT_PASSWORD)"
t_eq "DB_NAME flows into app.env MYSQL_DATABASE" customdb "$(envval "$R/app.env" MYSQL_DATABASE)"
t_eq "DB_NAME flows into db.env MARIADB_DATABASE" customdb "$(envval "$R/db.env" MARIADB_DATABASE)"
t_eq "DB_USER flows into app.env and db.env alike" "customuser customuser" "$(envval "$R/app.env" MYSQL_USER) $(envval "$R/db.env" MARIADB_USER)"
t_eq "TZ is the same across db/app/cron env files" 1 "$(for f in db app cron; do envval "$R/$f.env" TZ; done | sort -u | wc -l)"
t_eq "caddy.env upstream is the app container on port 80" "nextcloud-app:80" "$(envval "$R/caddy.env" NEXTCLOUD_UPSTREAM)"
# Idempotent: second run keeps redis-session.ini (it may have been filled by the container).
printf 'session.save=x\n' > "$R/redis-session.ini"
NEXTCLOUD_ENV_FILE="$T/wef-names.env" NEXTCLOUD_RUN_DIR="$R" in_setup 'write_env_files' >/dev/null 2>&1
t_eq "a second write_env_files preserves redis-session.ini content" "session.save=x" "$(cat "$R/redis-session.ini")"

# ===========================================================================
# 8. ensure_env
# ===========================================================================
gen_env() {  # gen_env DIR -> generates DIR/.env via ensure_env
    mkdir -p "$1"
    NEXTCLOUD_ENV_FILE="$1/.env" in_setup 'umask 022; ensure_env'
}
t_check "ensure_env generates a fresh env file" gen_env "$T/ge1"
G="$T/ge1/.env"
t_eq "generated env file is mode 600 (even under umask 022)" 600 "$(stat -c %a "$G")"
SECS=()
for k in DB_PASSWORD DB_ROOT_PASSWORD NEXTCLOUD_ADMIN_PASSWORD; do
    v="$(envval "$G" "$k")"; SECS+=("$v")
    t_match "$k is 48 hex characters" '^[0-9a-f]{48}$' "$v"
done
t_eq "the three secrets are mutually distinct" 3 "$(printf '%s\n' "${SECS[@]}" | sort -u | wc -l)"
t_nomatch "no 'change-me' placeholder remains in any setting" 'change-me' "$(grep -E '^[A-Z][A-Z0-9_]*=' "$G")"
t_match "DATA_HOST_PATH is absolute" '^/' "$(envval "$G" DATA_HOST_PATH)"
t_eq "DATA_HOST_PATH is <project>/data" "${T_ROOT}/data" "$(envval "$G" DATA_HOST_PATH)"
TD="$(envval "$G" NEXTCLOUD_TRUSTED_DOMAINS)"
t_match "trusted domains include localhost" '(^| )localhost( |$)' "$TD"
t_match "trusted domains include 127.0.0.1" '(^| )127\.0\.0\.1( |$)' "$TD"
t_match "trusted domains include this host name ($HOST_NOW)" "(^| )${HOST_NOW}( |\$)" "$TD"
LANIP="$(lan_ip)"
if [ -n "$LANIP" ]; then t_match "trusted domains include the LAN IP" "(^| )${LANIP//./\\.}( |\$)" "$TD"
else t_skip "LAN IP in trusted domains" "no LAN IP detected"; fi
t_match "overwrite CLI URL uses this host name" "^http://${HOST_NOW}:" "$(envval "$G" NEXTCLOUD_OVERWRITE_CLI_URL)"
t_match "TZ is set" '^.+$' "$(envval "$G" TZ)"
t_eq "generated file has exactly the keys of .env.example" \
    "$(grep -E '^[A-Z][A-Z0-9_]*=' .env.example | cut -d= -f1 | sort | tr '\n' ' ')" \
    "$(grep -E '^[A-Z][A-Z0-9_]*=' "$G" | cut -d= -f1 | sort | tr '\n' ' ')"
SUM1="$(sha256sum "$G" | cut -d' ' -f1)"
_out="$(gen_env "$T/ge1" 2>&1)"
t_eq "ensure_env twice: file is byte-identical (never regenerates secrets)" "$SUM1" "$(sha256sum "$G" | cut -d' ' -f1)"
t_match "ensure_env twice: says the file already exists" 'already exists' "$_out"
t_eq "ensure_env twice: mode still 600" 600 "$(stat -c %a "$G")"
t_check "ensure_env generates a second, independent env" gen_env "$T/ge2"
t_ne "negative control: two generations produce different DB passwords" "$(envval "$G" DB_PASSWORD)" "$(envval "$T/ge2/.env" DB_PASSWORD)"
t_eq "gen_secret yields 48 hex chars" 1 "$(S "$T/plain.env" 'gen_secret' | grep -cE '^[0-9a-f]{48}$')"

# ===========================================================================
# 9. ensure_tls
# ===========================================================================
tls() {  # tls DIR "trusted domains" -> runs ensure_tls with TLS_DIR=DIR
    mkenv "tlsenv" "NEXTCLOUD_TRUSTED_DOMAINS=$2"
    NEXTCLOUD_ENV_FILE="$T/tlsenv.env" in_setup "TLS_DIR='$1'; ensure_tls"
}
sans() {  # normalised, sorted SAN set of a cert: DNS:x / IP:x
    openssl x509 -noout -ext subjectAltName -in "$1/site.crt" | tail -n +2 | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/IP Address:/IP:/' | grep . | sort | tr '\n' ' '
}
expect_sans() {  # expect_sans domains... -> sorted set per the documented rule
    local n; { for n in localhost 127.0.0.1 "$HOST_NOW" "${HOST_NOW}.local" "$LANIP" "$@"; do
        [ -n "$n" ] || continue
        [[ "$n" =~ ^[^:]+:[0-9]+$ ]] && n="${n%:*}"
        if [[ "$n" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then echo "IP:$n"; else echo "DNS:$n"; fi
    done; } | sort -u | tr '\n' ' '
}
D1="$T/tls1"
t_check "ensure_tls generates a certificate into a temp TLS_DIR" tls "$D1" "localhost 127.0.0.1 extra.example 192.0.2.9"
t_eq "SAN set equals localhost, 127.0.0.1, host, host.local, LAN ip and the trusted domains" \
    "$(expect_sans extra.example 192.0.2.9)" "$(sans "$D1")"
t_eq "key mode 600" 600 "$(stat -c %a "$D1/site.key")"
t_eq "cert mode 644" 644 "$(stat -c %a "$D1/site.crt")"
t_match "subject CN is the host name" "CN *= *${HOST_NOW}\$" "$(openssl x509 -noout -subject -in "$D1/site.crt")"
t_check "cert is valid for at least 30 more days" openssl x509 -checkend 2592000 -noout -in "$D1/site.crt"
t_check "key matches the certificate" bash -c "[ \"\$(openssl x509 -noout -pubkey -in '$D1/site.crt')\" = \"\$(openssl pkey -pubout -in '$D1/site.key')\" ]"
SHA1="$(sha256sum "$D1/site.crt" | cut -d' ' -f1)"
tls "$D1" "localhost 127.0.0.1 extra.example 192.0.2.9" >/dev/null 2>&1
t_eq "idempotent: second run keeps the same cert" "$SHA1" "$(sha256sum "$D1/site.crt" | cut -d' ' -f1)"
tls "$D1" "localhost" >/dev/null 2>&1
t_eq "a cert that covers a superset of the wanted names is kept" "$SHA1" "$(sha256sum "$D1/site.crt" | cut -d' ' -f1)"

# host:port -> DNS:host
D2="$T/tls2"
tls "$D2" "localhost foo:8443 192.0.2.9:8443" >/dev/null 2>&1
S2="$(sans "$D2")"
t_match "trusted domain foo:8443 yields DNS:foo" '(^| )DNS:foo( |$)' "$S2"
t_nomatch "no SAN keeps the port (DNS:foo:8443)" 'foo:8443' "$S2"
t_match "trusted domain 192.0.2.9:8443 yields IP:192.0.2.9" '(^| )IP:192\.0\.2\.9( |$)' "$S2"
t_nomatch "no SAN keeps the port on an IP either" '192\.0\.2\.9:8443' "$S2"

# A NEW trusted domain regenerates.
SHA2="$(sha256sum "$D2/site.crt" | cut -d' ' -f1)"
tls "$D2" "localhost foo:8443 192.0.2.9:8443 brand-new.example" >/dev/null 2>&1
t_ne "a new trusted domain regenerates the cert" "$SHA2" "$(sha256sum "$D2/site.crt" | cut -d' ' -f1)"
t_match "the regenerated cert has the new name" '(^| )DNS:brand-new\.example( |$)' "$(sans "$D2")"
t_match "the regenerated cert keeps the old names" '(^| )DNS:foo( |$)' "$(sans "$D2")"

# Prefix look-alike: have 192.0.2.50, want 192.0.2.5 -> must regenerate (exact match).
D3="$T/tls3"
tls "$D3" "localhost 192.0.2.50" >/dev/null 2>&1
t_match "setup for look-alike: cert has IP:192.0.2.50" '(^| )IP:192\.0\.2\.50( |$)' "$(sans "$D3")"
t_nomatch "setup for look-alike: cert does NOT have IP:192.0.2.5" '(^| )IP:192\.0\.2\.5( |$)' "$(sans "$D3")"
SHA3="$(sha256sum "$D3/site.crt" | cut -d' ' -f1)"
tls "$D3" "localhost 192.0.2.5" >/dev/null 2>&1
t_ne "wanting 192.0.2.5 while the cert has 192.0.2.50 regenerates (exact match)" "$SHA3" "$(sha256sum "$D3/site.crt" | cut -d' ' -f1)"
t_match "the new cert has IP:192.0.2.5" '(^| )IP:192\.0\.2\.5( |$)' "$(sans "$D3")"
# And the opposite look-alike (suffix): have 10.0.2.5, want 0.2.5-style names are not IPs; use DNS: have a.example, want aa.example
D4="$T/tls4"
tls "$D4" "localhost a.example" >/dev/null 2>&1; SHA4="$(sha256sum "$D4/site.crt" | cut -d' ' -f1)"
tls "$D4" "localhost aa.example" >/dev/null 2>&1
t_ne "DNS look-alike (a.example vs aa.example) regenerates" "$SHA4" "$(sha256sum "$D4/site.crt" | cut -d' ' -f1)"
# An expired/near-expiry cert is replaced.
D5="$T/tls5"; mkdir -p "$D5"
( umask 077; openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj "/CN=old" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:${HOST_NOW},DNS:${HOST_NOW}.local${LANIP:+,IP:$LANIP}" \
    -keyout "$D5/site.key" -out "$D5/site.crt" >/dev/null 2>&1 )
SHA5="$(sha256sum "$D5/site.crt" | cut -d' ' -f1)"
tls "$D5" "localhost" >/dev/null 2>&1
t_ne "a certificate expiring within 30 days is regenerated" "$SHA5" "$(sha256sum "$D5/site.crt" | cut -d' ' -f1)"

# ===========================================================================
# 10. naming helpers
# ===========================================================================
for s in db redis app cron caddy network x-y; do
    t_eq "unit_of $s" "nextcloud-$s.service" "$(S "$T/plain.env" "unit_of $s")"
done
t_eq "SERVICES start order is db redis app cron caddy" "db redis app cron caddy" "$(S "$T/plain.env" 'echo "${SERVICES[*]}"')"
for s in db redis app cron caddy; do
    t_check "every service has a template whose rendered name matches unit_of: $s" test -e "systemd/nextcloud-$s.container.in"
done
for s in db redis app cron caddy; do
    c="nextcloud-$s"
    if podman container exists "$c" 2>/dev/null; then
        t_check_not "is_legacy_container $c is false for a Quadlet-managed container" S "$T/plain.env" "is_legacy_container $c"
    else
        t_skip "is_legacy_container $c" "container not present"
    fi
done
t_check "negative control: a container that does not exist counts as non-Quadlet (legacy)" S "$T/plain.env" 'is_legacy_container nextcloud-t09-no-such-container'
t_eq "me_user / me_uid / me_gid come from id" "$(id -un) $(id -u) $(id -g)" "$(S "$T/plain.env" 'echo "$(me_user) $(me_uid) $(me_gid)"')"
t_eq "detect_timezone honours TZ" "Europe/Test" "$(TZ=Europe/Test S "$T/plain.env" 'detect_timezone')"
t_eq "network_subnets equals the live network (read-only)" "$NET_TRUTH" "$(S "$T/plain.env" 'network_subnets')"

t_end
