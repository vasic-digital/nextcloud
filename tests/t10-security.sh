#!/usr/bin/env bash
# t10-security: secrets handling, least privilege, exposure, Nextcloud hardening. READ-ONLY.
. "$(dirname "$0")/lib.sh"
t_begin t10 "security posture"

ME="$(id -u)"
SVCS=(db redis app cron caddy)
ENVF="${NEXTCLOUD_ENV_FILE:-.env}"
mode_of() { stat -c %a "$1" 2>/dev/null; }

# ---- file permissions ------------------------------------------------------------
t_eq ".env mode" 600 "$(mode_of "$ENVF")"
t_eq ".env owner" "$ME" "$(stat -c %u "$ENVF")"
t_eq ".run directory mode" 700 "$(mode_of .run)"
envs=(.run/*.env)
t_ge ".run holds env files" 4 "${#envs[@]}"
for f in "${envs[@]}"; do t_eq "$f mode" 600 "$(mode_of "$f")"; done
t_eq "tls/site.key mode" 600 "$(mode_of tls/site.key)"
t_eq "tls/site.key owner" "$ME" "$(stat -c %u tls/site.key)"
t_check "tls/site.crt is readable and a valid certificate" openssl x509 -in tls/site.crt -noout
t_check_not "negative control: the mode check would flag a world-readable file (tls/site.crt is not 600)" test "$(mode_of tls/site.crt)" != 644 -a "$(mode_of tls/site.crt)" != 600

# ---- secrets reach only the containers that need them -----------------------------------
envof() { podman inspect "nextcloud-$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null; }
val() { sed -n "s/^$1=//p" "$ENVF" | tail -1; }
# contains_value CONTAINER KEY_IN_.env  -> rc 0 when the container env contains that value (nothing printed)
contains_value() { local v; v="$(val "$2")"; [ -n "$v" ] || return 2; envof "$1" | cut -d= -f2- | grep -qxF -- "$v"; }
ROOTPW="$(val DB_ROOT_PASSWORD)"; ADMPW="$(val NEXTCLOUD_ADMIN_PASSWORD)"
t_ge "DB root password is configured (>= 16 chars)" 16 "${#ROOTPW}"
t_ge "admin password is configured (>= 12 chars)" 12 "${#ADMPW}"
t_check "positive control: db container env has MARIADB_ROOT_PASSWORD" bash -c 'podman inspect nextcloud-db --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -q "^MARIADB_ROOT_PASSWORD="'
t_check "positive control: db env value equals DB_ROOT_PASSWORD (comparison works)" contains_value db DB_ROOT_PASSWORD
for s in app cron caddy redis; do
    t_check_not "nextcloud-$s env does not contain the DB root password" contains_value "$s" DB_ROOT_PASSWORD
    t_check_not "nextcloud-$s env does not contain the admin password" contains_value "$s" NEXTCLOUD_ADMIN_PASSWORD
done
t_check_not "db env does not contain the admin password" contains_value db NEXTCLOUD_ADMIN_PASSWORD

# ---- trusted proxies equal the real network ----------------------------------------------
subnets="$(podman network inspect nextcloud-net -f '{{range .Subnets}}{{.Subnet}} {{end}}' | sed 's/ $//')"
override="$(val TRUSTED_PROXIES)"
want="${override:-$subnets}"
t_ne "network subnet(s) discovered" "" "$subnets"
got="$(envof app | sed -n 's/^TRUSTED_PROXIES=//p')"
t_eq "app TRUSTED_PROXIES equals ${override:+the .env override}${override:-the nextcloud-net subnet(s)}" "$want" "$got"
t_nomatch "TRUSTED_PROXIES has no catch-all (0.0.0.0/0, ::/0, /0)" '(^|[ ,])(0\.0\.0\.0|::)(/0)?([ ,]|$)|/0([ ,]|$)' "$got"
t_match "negative control: the catch-all regex does match 0.0.0.0/0" '/0([ ,]|$)' "10.0.0.0/8 0.0.0.0/0"

# ---- exposure -------------------------------------------------------------------------------
BIND="$(cfg NEXTCLOUD_BIND)"; HP="$(cfg NEXTCLOUD_PORT)"; SP="$(cfg NEXTCLOUD_HTTPS_PORT)"   # .env, else the documented default in .env.example
for s in db redis; do
    t_eq "nextcloud-$s: podman port prints nothing" "" "$(podman port nextcloud-$s 2>&1)"
    t_eq "nextcloud-$s: no PortBindings" "map[]" "$(podman inspect nextcloud-$s --format '{{.HostConfig.PortBindings}}')"
    t_eq "nextcloud-$s: no published ports in the container config" "" "$(podman inspect nextcloud-$s --format '{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}{{$p}} {{end}}{{end}}')"
done
all_pub="$(for s in "${SVCS[@]}"; do podman port "nextcloud-$s" 2>/dev/null; done | awk '{print $1 " " $3}' | sort | tr '\n' ';')"
t_eq "published host sockets are exactly $HP/tcp and $SP/tcp+udp" "443/tcp $BIND:$SP;443/udp $BIND:$SP;80/tcp $BIND:$HP;" "$all_pub"
t_eq "bind address is the configured one ($BIND)" 3 "$(for s in app caddy; do podman port nextcloud-$s; done | grep -c -- "-> $BIND:")"

# ---- container privileges ---------------------------------------------------------------------
for s in "${SVCS[@]}"; do
    c="nextcloud-$s"
    ins() { podman inspect "$c" --format "$1"; }
    t_eq "$c is not privileged" false "$(ins '{{.HostConfig.Privileged}}')"
    t_eq "$c adds no capabilities" "[]" "$(ins '{{.HostConfig.CapAdd}}')"
    t_eq "$c has no devices" "[]" "$(ins '{{.HostConfig.Devices}}')"
    t_nomatch "$c does not use the host network" '^host$' "$(ins '{{.HostConfig.NetworkMode}}')"
    t_nomatch "$c does not share the host PID namespace" '^host$' "$(ins '{{.HostConfig.PidMode}}')"
    t_nomatch "$c does not share the host IPC namespace" '^host$' "$(ins '{{.HostConfig.IpcMode}}')"
    t_nomatch "$c does not share the host user namespace" '^host$' "$(ins '{{.HostConfig.UsernsMode}}')"
    t_nomatch "$c has no unconfined security option" 'unconfined' "$(ins '{{.HostConfig.SecurityOpt}}')"
    t_nomatch "$c mounts no container-engine socket" '(docker|podman)\.sock|/var/run/docker|/run/podman' "$(ins '{{range .Mounts}}{{.Source}} {{.Destination}} {{end}}')"
done
t_match "negative control: the socket regex does flag a docker.sock mount" '(docker|podman)\.sock' "/var/run/docker.sock /var/run/docker.sock"

# Host bind mounts: explicit allowlist (source -> must be read-only?), built from configuration.
DATA="$(data_dir)"
declare -A ALLOW=(
    ["$T_ROOT/Caddyfile"]=ro
    ["$T_ROOT/tls"]=ro
    ["$T_ROOT/config/nextcloud-hooks"]=ro
    ["$T_ROOT/.run/redis-session.ini"]=rw
    ["$DATA"]=rw )
unexpected=""; wrongmode=""; seen=""
for s in "${SVCS[@]}"; do
    while IFS='|' read -r src rw; do
        [ -n "$src" ] || continue
        seen="$seen $src"
        mwant="${ALLOW[$src]:-}"
        if [ -z "$mwant" ]; then unexpected="$unexpected nextcloud-$s:$src"
        elif [ "$mwant" = ro ] && [ "$rw" = true ]; then wrongmode="$wrongmode nextcloud-$s:$src"; fi
    done < <(podman inspect "nextcloud-$s" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.RW}}{{"\n"}}{{end}}{{end}}')
done
t_eq "every host bind mount is on the allowlist" "" "$unexpected"
t_eq "Caddyfile, tls and the hooks are mounted read-only" "" "$wrongmode"
for p in "${!ALLOW[@]}"; do t_match "allowlisted mount is actually used: $p" "(^| )$p( |\$)" "$seen"; done
t_eq "only the data dir and the session ini are writable host mounts" "" \
    "$(for k in "${!ALLOW[@]}"; do [ "${ALLOW[$k]}" = rw ] && echo "$k"; done | sort | grep -vxF -e "$DATA" -e "$T_ROOT/.run/redis-session.ini")"
t_eq "negative control: an arbitrary path is not allowlisted" "" "${ALLOW[/etc]:-}"

# ---- Caddy and TLS --------------------------------------------------------------------------------
t_nomatch "Caddyfile serves nothing from the host filesystem (no file_server/root/browse)" '(^|[[:space:]])(file_server|root[[:space:]]|browse|templates)\b' "$(grep -v '^[[:space:]]*#' Caddyfile)"
t_match "Caddyfile only reverse-proxies" 'reverse_proxy' "$(grep -v '^[[:space:]]*#' Caddyfile)"
t_match "negative control: the file_server regex does detect it" '(^|[[:space:]])file_server\b' "  file_server browse"
fp() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'; }
live_fp="$(echo | timeout 15 openssl s_client -connect "127.0.0.1:$SP" 2>/dev/null | fp)"
file_fp="$(fp < tls/site.crt)"
t_match "TLS endpoint returned a certificate" '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' "$live_fp"
t_eq "the HTTPS endpoint presents the generated certificate (sha256)" "$file_fp" "$live_fp"
t_check_not "plain HTTP is not offered on the HTTPS port" curl -s --max-time 5 "http://127.0.0.1:$SP/status.php" -o /dev/null --fail

# ---- Nextcloud-level settings ----------------------------------------------------------------------
occ() { ./setup.sh occ "$@" 2>/dev/null; }
t_eq "overwriteprotocol is not forced (plain HTTP must keep working)" "" "$(occ config:system:get overwriteprotocol || true)"
t_eq "trusted_proxies[0] equals the discovered subnet" "${want%% *}" "$(occ config:system:get trusted_proxies 0)"
t_eq "lost_password_link is disabled" disabled "$(occ config:system:get lost_password_link)"
conf="$(podman exec nextcloud-app sh -c 'cat /var/www/html/config/config.php' 2>/dev/null)"
t_match "config.php is readable and sane" "'instanceid'" "$conf"
t_nomatch "config.php has no bogus trustedProxies* keys" "trustedProxies" "$conf"
t_nomatch "config.php has no bogus overwrite.protocol key" "overwrite\\.protocol" "$conf"
t_nomatch "config.php does not force overwriteprotocol" "'overwriteprotocol'" "$conf"
t_match "negative control: the junk-key regex does detect 'trustedProxies.0'" "trustedProxies" "'trustedProxies.0' => 1"

# ---- repository hygiene ------------------------------------------------------------------------------
tracked="$(git ls-files)"
t_nomatch "no secret paths are tracked (.env, .run/, tls/, backups/)" '(^|\n)(\.env|\.run/|tls/|backups/)' "$(printf '%s\n' "$tracked" | grep -E '^(\.env$|\.env\.local|\.run/|tls/|backups/)')"
t_ge "git tracks files (the check is not vacuous)" 5 "$(printf '%s\n' "$tracked" | wc -l)"
for p in .env .run/app.env tls/site.key backups/x; do t_check "$p is git-ignored" git check-ignore -q "$p"; done
t_check_not "negative control: a tracked file is not git-ignored" git check-ignore -q setup.sh

t_end
