#!/usr/bin/env bash
# t02-units: the systemd --user Quadlet units that make up the stack. READ-ONLY.
. "$(dirname "$0")/lib.sh"
t_begin t02 "systemd user units, containers, ports"

UID_N="$(id -u)"
GEN="/run/user/$UID_N/systemd/generator"
SVCS=(db redis app cron caddy)
sc() { systemctl --user "$@"; }
prop() { sc show -p "$2" --value "$1" 2>/dev/null; }
has_word() { [[ " $1 " == *" $2 "* ]]; }   # has_word "list of words" word

# ---- unit files exist and are generated from the Quadlet sources ----------
for s in network "${SVCS[@]}"; do
    u="nextcloud-$s.service"
    t_check "$u is a generated unit (fragment under $GEN)" \
        bash -c '[[ "$(systemctl --user show -p FragmentPath --value "$1")" == "$2"/* ]] && [ -s "$(systemctl --user show -p FragmentPath --value "$1")" ]' _ "$u" "$GEN"
    src="$(prop "$u" SourcePath)"
    t_match "$u SourcePath is a Quadlet file in the user's containers/systemd dir" \
        '/containers/systemd/nextcloud[^/]*\.(container|network)$' "$src"
    t_check "$u Quadlet source file exists" test -f "$src"
done

# ---- activity ---------------------------------------------------------------
for s in "${SVCS[@]}"; do
    u="nextcloud-$s.service"
    t_eq "$u ActiveState" active "$(prop "$u" ActiveState)"
    t_eq "$u SubState" running "$(prop "$u" SubState)"
done
t_eq "nextcloud-network.service ActiveState" active "$(prop nextcloud-network.service ActiveState)"
t_eq "nextcloud-network.service SubState" exited "$(prop nextcloud-network.service SubState)"
t_check "podman network nextcloud-net exists" podman network exists nextcloud-net
t_check "the network has a subnet" bash -c '[ -n "$(podman network inspect nextcloud-net -f "{{range .Subnets}}{{.Subnet}} {{end}}")" ]'

# ---- restart policy, boot wiring --------------------------------------------
deps="$(sc list-dependencies --plain --no-legend default.target 2>/dev/null | tr -d ' ')"
for s in "${SVCS[@]}"; do
    u="nextcloud-$s.service"
    t_eq "$u Restart=" always "$(prop "$u" Restart)"
    t_check "$u is wanted by default.target (generator symlink)" test -L "$GEN/default.target.wants/$u"
    t_match "$u appears in default.target's dependency tree" "(^|[[:space:]])$u([[:space:]]|\$)" "$(printf '%s ' $deps)"
done
t_check_not "negative control: a made-up unit is NOT wanted by default.target" test -e "$GEN/default.target.wants/nextcloud-bogus.service"
t_eq "linger enabled for $(id -un)" yes "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"

# ---- dependency graph ---------------------------------------------------------
rq() { prop "nextcloud-$1.service" Requires; }
af() { prop "nextcloud-$1.service" After; }
wn() { prop "nextcloud-$1.service" Wants; }
for d in db redis; do
    t_check "app Requires nextcloud-$d.service" has_word "$(rq app)" "nextcloud-$d.service"
    t_check "app starts After nextcloud-$d.service" has_word "$(af app)" "nextcloud-$d.service"
done
t_check "cron Requires nextcloud-app.service" has_word "$(rq cron)" nextcloud-app.service
t_check "cron starts After nextcloud-app.service" has_word "$(af cron)" nextcloud-app.service
t_check "caddy Wants nextcloud-app.service" has_word "$(wn caddy)" nextcloud-app.service
t_check "caddy starts After nextcloud-app.service" has_word "$(af caddy)" nextcloud-app.service
t_check_not "caddy does NOT hard-Require app (a web restart must not stop TLS)" has_word "$(rq caddy)" nextcloud-app.service
t_check_not "negative control: db does not Require app" has_word "$(rq db)" nextcloud-app.service
for s in "${SVCS[@]}"; do
    t_check "nextcloud-$s.service starts After nextcloud-network.service" has_word "$(af $s)" nextcloud-network.service
done

# ---- containers belong to their units, no strays ------------------------------
names="$(podman ps -a --filter name=nextcloud --format '{{.Names}}' | sort | tr '\n' ' ')"
expected="$(printf 'nextcloud-%s\n' "${SVCS[@]}" | sort | tr '\n' ' ')"
t_eq "the only containers named *nextcloud* are the five stack containers" "$expected" "$names"
for s in "${SVCS[@]}"; do
    c="nextcloud-$s"
    t_eq "$c label PODMAN_SYSTEMD_UNIT" "$c.service" "$(podman inspect "$c" --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' 2>/dev/null)"
    t_eq "$c is not a compose container (no compose project label)" "" "$(podman inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}{{index .Config.Labels "io.podman.compose.project"}}' 2>/dev/null)"
    t_eq "$c state" running "$(podman inspect "$c" --format '{{.State.Status}}' 2>/dev/null)"
done
for s in db redis app; do
    # (a freshly started container is 'starting' until its first healthcheck passes: wait, do not sample once)
    t_wait "nextcloud-$s health" 150 bash -c "[ \"\$(podman inspect -f '{{.State.Health.Status}}' nextcloud-$s 2>/dev/null)\" = healthy ]"
done
failed="$(sc --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep '^nextcloud-' | tr '\n' ' ')"
t_eq "no failed nextcloud-* units" "" "$failed"

# ---- images match configuration ------------------------------------------------
declare -A KEY=([db]=db [redis]=redis [app]=nextcloud [cron]=nextcloud [caddy]=caddy)
for s in "${SVCS[@]}"; do
    want="$(in_setup "image_of ${KEY[$s]}" 2>/dev/null)"
    t_ne "configured image for $s is non-empty" "" "$want"
    t_eq "nextcloud-$s runs the configured image" "$want" "$(podman inspect "nextcloud-$s" --format '{{.ImageName}}' 2>/dev/null)"
done
t_eq "app and cron run the same image (no version drift)" \
    "$(podman inspect nextcloud-app --format '{{.Image}}')" "$(podman inspect nextcloud-cron --format '{{.Image}}')"

# ---- restart loop detection: sample twice, 10 s apart ----------------------------
declare -A N1 N2
for s in "${SVCS[@]}"; do N1[$s]="$(prop "nextcloud-$s.service" NRestarts)"; done
sleep 10
for s in "${SVCS[@]}"; do
    N2[$s]="$(prop "nextcloud-$s.service" NRestarts)"
    t_match "nextcloud-$s NRestarts is numeric" '^[0-9]+$' "${N2[$s]}"
    if [[ "${N1[$s]}" =~ ^[0-9]+$ && "${N2[$s]}" =~ ^[0-9]+$ && "${N2[$s]}" -le "${N1[$s]}" ]]; then
        t_pass "nextcloud-$s did not restart during the 10 s window (${N1[$s]} -> ${N2[$s]})"
    else
        t_fail "nextcloud-$s restarted during the 10 s window (restart loop?)" "${N1[$s]} -> ${N2[$s]}"
    fi
done

# ---- published ports --------------------------------------------------------------
BIND="$(cfg NEXTCLOUD_BIND)"; HP="$(cfg NEXTCLOUD_PORT)"; SP="$(cfg NEXTCLOUD_HTTPS_PORT)"   # .env, else the documented default in .env.example
ports_of() { podman port "nextcloud-$1" 2>/dev/null | sed 's/ //g' | sort | tr '\n' ' '; }
t_eq "app publishes exactly HTTP $BIND:$HP -> 80/tcp" "80/tcp->$BIND:$HP " "$(ports_of app)"
t_eq "caddy publishes exactly HTTPS $BIND:$SP -> 443 tcp+udp" "443/tcp->$BIND:$SP 443/udp->$BIND:$SP " "$(ports_of caddy)"
for s in db redis cron; do
    t_eq "nextcloud-$s publishes nothing" "" "$(ports_of $s)"
    t_eq "nextcloud-$s has no PortBindings in its config" "map[]" "$(podman inspect nextcloud-$s --format '{{.HostConfig.PortBindings}}')"
done
ss_has() { ss -ltnuH 2>/dev/null | awk -v p=":$2\$" -v n="$1" -v st="$3" '$1 == n && $2 == st && $5 ~ p {f=1} END{exit !f}'; }
t_check "host listens on tcp $HP" ss_has tcp "$HP" LISTEN
t_check "host listens on tcp $SP" ss_has tcp "$SP" LISTEN
t_check "host listens on udp $SP (HTTP/3)" ss_has udp "$SP" UNCONN
t_check_not "negative control: nothing of ours listens on an unrelated tcp port ($((SP+1)))" ss_has tcp "$((SP+1))" LISTEN
# Everything the stack publishes, read from all five containers at once: exactly three host sockets.
all_pub="$(for s in "${SVCS[@]}"; do podman port "nextcloud-$s" 2>/dev/null; done | awk '{print $1 " " $3}' | sort | tr '\n' ';')"
t_eq "the whole stack publishes exactly three host sockets" "443/tcp $BIND:$SP;443/udp $BIND:$SP;80/tcp $BIND:$HP;" "$all_pub"

# ---- user namespace -----------------------------------------------------------------
for s in app db redis cron; do
    ann="$(podman inspect "nextcloud-$s" --format '{{index .Config.Annotations "io.podman.annotations.userns"}}' 2>/dev/null)"
    t_match "nextcloud-$s runs with the pinned user namespace keep-id:uid=N,gid=N" '^keep-id:uid=[0-9]+,gid=[0-9]+$' "$ann"
done
t_eq "nextcloud-caddy has no user-namespace override (container-root maps to you)" "" "$(podman inspect nextcloud-caddy --format '{{index .Config.Annotations "io.podman.annotations.userns"}}')"
t_eq "app and cron pin the same ids" \
    "$(podman inspect nextcloud-app --format '{{index .Config.Annotations "io.podman.annotations.userns"}}')" \
    "$(podman inspect nextcloud-cron --format '{{index .Config.Annotations "io.podman.annotations.userns"}}')"

# ---- healthchecks on every service (and proof they can fail) ---------------------------
for s in db redis app cron caddy; do
    t_wait "nextcloud-$s reports healthy" 150 bash -c "[ \"\$(podman inspect -f '{{.State.Health.Status}}' nextcloud-$s)\" = healthy ]"
done
for s in db redis app cron caddy; do
    t_match "nextcloud-$s has a healthcheck command configured" '.' "$(podman inspect -f '{{.Config.Healthcheck.Test}}' nextcloud-$s)"
done
# The exact commands from the units, run where they must FAIL:
cron_hc="$(podman inspect -f '{{index .Config.Healthcheck.Test 1}}' nextcloud-cron 2>/dev/null)"
[ -n "$cron_hc" ] || cron_hc="$(podman inspect -f '{{.Config.Healthcheck.Test}}' nextcloud-cron)"
t_check "cron's healthcheck command succeeds in the cron container" podman exec nextcloud-cron sh -c "${cron_hc#CMD-SHELL }"
t_check_not "negative control: cron's healthcheck FAILS where no crond runs (app container)" podman exec nextcloud-app sh -c "${cron_hc#CMD-SHELL }"
t_check "caddy's healthcheck target answers on its admin port" podman exec nextcloud-caddy wget -q -O /dev/null http://localhost:2019/config/
t_check_not "negative control: the same probe on a wrong port FAILS" podman exec nextcloud-caddy wget -q -T 3 -O /dev/null http://localhost:2020/config/

t_end
