#!/usr/bin/env bash
# ===========================================================================
#  t07-resilience — DISRUPTIVE live tests of lifecycle behaviour.
#
#  Restarts services, kills processes, stops the whole stack, uninstalls and
#  reinstalls the units, and occupies a port. The stack is back and healthy at
#  the end (also on failure: the EXIT trap restores .env and starts it again).
#
#  Proves: `up` is idempotent; configuration drift is detected and applied by
#  `restart`; systemd restarts killed processes; dependants follow a restart of
#  the database; units start correctly in ANY order (boot is parallel);
#  `cron` stops promptly and cleanly; `uninstall` keeps the data and `up`
#  brings the same instance back; a busy port is refused before anything starts;
#  leftover non-Quadlet containers are replaced but unrelated ones survive;
#  bad configuration is refused with clear errors.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t07-resilience "lifecycle, self-healing, boot order, uninstall/reinstall"

HTTP_PORT="$(nc_http_port)"; HTTPS_PORT="$(nc_https_port)"
TMP="$(t_tmpdir)"
cp -p .env "$TMP/env.orig"
LISTENER_PID=""; FOO=""
cleanup() {
    [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
    [ -n "$FOO" ] && podman rm -f "$FOO" >/dev/null 2>&1
    podman rm -f t07-legacy-probe >/dev/null 2>&1
    cmp -s "$TMP/env.orig" .env || { cp -p "$TMP/env.orig" .env; }
    if ! stack_healthy; then "$T_ROOT/setup.sh" up >/dev/null 2>&1; fi
    _t_cleanup_tmp
}
trap cleanup EXIT

# (named functions, not `bash -c`: t_check/t_wait run in this shell's subshell, so they see these)
upload_marker() { [ "$(dav PUT "$marker.txt" -T "$TMP/marker.txt" -o /dev/null -w '%{http_code}')" = 201 ]; }
marker_same()   { dav GET "$marker.txt" | cmp -s - "$TMP/marker.txt"; }
port_busy()     { ss -ltnH "sport = :$HTTP_PORT" | grep -q .; }

t_wait "precondition: the stack is healthy" 120 stack_healthy

# ---- 1. idempotent up --------------------------------------------------------
ids_before="$(stack_ctr_ids)"
run_setup up
t_eq "up on a running stack exits 0" "0" "$SETUP_RC"
t_eq "up does not recreate any container (ids unchanged)" "$ids_before" "$(stack_ctr_ids)"
t_nomatch "up on an unchanged stack reports no configuration drift" 'configuration changed' "$SETUP_OUT"

# ---- 2. configuration drift is detected, and restart applies it -------------------
orig_window="$(cfg NEXTCLOUD_MAINTENANCE_WINDOW_START 1)"
new_window=$(( (orig_window + 2) % 24 ))
if grep -q '^NEXTCLOUD_MAINTENANCE_WINDOW_START=' .env; then
    sed -i "s|^NEXTCLOUD_MAINTENANCE_WINDOW_START=.*|NEXTCLOUD_MAINTENANCE_WINDOW_START=$new_window|" .env
else
    printf 'NEXTCLOUD_MAINTENANCE_WINDOW_START=%s\n' "$new_window" >> .env
fi
run_setup up
t_match "after editing .env, up warns that a restart is needed" 'run ./setup.sh restart' "$SETUP_OUT"
t_eq "the running instance still has the OLD value (nothing applied silently)" "$orig_window" "$(occ config:system:get maintenance_window_start | tr -d '\r\n')"
run_setup restart
t_eq "restart exits 0" "0" "$SETUP_RC"
t_wait "stack healthy after restart" 180 stack_healthy
t_eq "restart applied the new value through .env -> app.env -> hook" "$new_window" "$(occ config:system:get maintenance_window_start | tr -d '\r\n')"
run_setup up
t_nomatch "no drift reported once applied" 'configuration changed' "$SETUP_OUT"
cp -p "$TMP/env.orig" .env
run_setup restart
t_wait "stack healthy after reverting" 180 stack_healthy
t_eq "reverted value is back" "$orig_window" "$(occ config:system:get maintenance_window_start | tr -d '\r\n')"

# ---- 3. systemd restarts killed processes ------------------------------------------
marker="t07-$$-$(date +%s)"
printf 'survives restarts %s\n' "$marker" > "$TMP/marker.txt"
t_check "marker file uploaded through Nextcloud" upload_marker

for svc in app redis; do
    pid="$(podman inspect -f '{{.State.Pid}}' "nextcloud-$svc")"
    n0="$(systemctl --user show -p NRestarts --value "$(t_unit $svc)")"
    kill -9 "$pid"
    # The stack still LOOKS healthy for a moment after the kill (systemd has not
    # noticed yet), so first wait until the restart has been observed, and only
    # then wait for full health again.
    restarted() { [ "$(systemctl --user show -p NRestarts --value "$(t_unit "$svc")")" -gt "$n0" ]; }
    t_wait "$svc: killed (SIGKILL) -> systemd restarts the unit (restart counter increases)" 90 restarted
    t_wait "$svc: stack healthy again after the automatic restart" 180 stack_healthy
    n1="$(systemctl --user show -p NRestarts --value "$(t_unit $svc)")"
    t_ge "$svc: systemd counted the automatic restart" "$((n0 + 1))" "$n1"
    new_pid="$(podman inspect -f '{{.State.Pid}}' "nextcloud-$svc")"
    t_ne "$svc: it is a NEW process (the old pid is gone)" "$pid" "$new_pid"
    t_check "$svc: the file survived the crash" marker_same
done

# ---- 4. restarting the database brings the dependants back --------------------------
systemctl --user restart "$(t_unit db)"
t_wait "database restart: all five units active and web healthy again" 240 stack_healthy
t_check "data intact after the database restart" marker_same
t_eq "database answers (information_schema reachable)" "1" "$(podman exec nextcloud-db sh -c 'mariadb -N -u root -p"$MARIADB_ROOT_PASSWORD" -e "select 1"' 2>/dev/null | tr -d '\r\n')"

# ---- 5. cron stops promptly and is not reported as failed -------------------------------
t0=$(date +%s%3N); systemctl --user stop "$(t_unit cron)"; t1=$(date +%s%3N)
ms=$((t1 - t0))
t_pass "cron stop took ${ms} ms" "ms=$ms"
[ "$ms" -lt 5000 ] && t_pass "cron stops in under 5 s (it used to take 10 s and be SIGKILLed)" || t_fail "cron stop was slow: ${ms} ms"
t_eq "cron stop recorded as success" "success" "$(systemctl --user show -p Result --value "$(t_unit cron)")"
t_eq "no failed nextcloud units after stopping cron" "" "$(systemctl --user --failed --no-legend | awk '{print $2}' | grep '^nextcloud-' | tr '\n' ' ' | sed 's/ $//')"
systemctl --user start "$(t_unit cron)"
t_wait "cron active again" 30 systemctl --user is-active --quiet "$(t_unit cron)"

# ---- 6. boot order: start everything at once, in the WORST order -----------------------
run_setup down
t_eq "down exits 0" "0" "$SETUP_RC"
active_after_down=0; for s in $(t_services); do systemctl --user is-active --quiet "$(t_unit "$s")" && active_after_down=$((active_after_down + 1)); done
t_eq "down: no unit is active" "0" "$active_after_down"
t_eq "down: no nextcloud container remains" "0" "$(podman ps -a --format '{{.Names}}' | grep -c '^nextcloud-')"
# Dependants first, dependencies last — what a parallel boot could do.
rev=(); for s in $(t_services); do rev=("$(t_unit "$s")" "${rev[@]}"); done
systemctl --user start "${rev[@]}"
t_check "all units started from a cold start in reverse-dependency order" stack_all_active
t_wait "web healthy after the cold start" 240 stack_healthy
t_eq "wants links: the generator enrols every service in default.target (boot start)" "5" \
    "$(systemctl --user show -p Wants --value default.target | tr ' ' '\n' | grep -c '^nextcloud-.*\.service$')"
t_eq "linger is enabled (services start at boot without a login)" "yes" "$(loginctl show-user "$(me_user)" -p Linger --value)"
t_check "file still there after a full stop/start" marker_same

# ---- 7. uninstall keeps data; up brings the same instance back -------------------------
inst_before="$(occ config:system:get instanceid | tr -d '\r\n')"
run_setup uninstall
t_eq "uninstall exits 0" "0" "$SETUP_RC"
t_eq "uninstall: no nextcloud unit files remain" "0" "$(ls "${XDG_CONFIG_HOME:-$HOME/.config}"/containers/systemd/nextcloud* 2>/dev/null | wc -l)"
t_check_not "uninstall: systemd no longer knows nextcloud-app.service" systemctl --user cat nextcloud-app.service
t_eq "uninstall: no container remains" "0" "$(podman ps -a --format '{{.Names}}' | grep -c '^nextcloud-')"
t_check "uninstall kept the html volume" podman volume exists "$(in_setup 'echo $VOL_HTML')"
t_check "uninstall kept the database volume" podman volume exists "$(in_setup 'echo $VOL_DB')"
t_check "uninstall kept .env and the certificate" test -f .env -a -f tls/site.crt
t_check "uninstall kept the user data" test -f "$(data_dir)/$(nc_admin_user)/files/$marker.txt"
t_check_not "uninstall removed the generated env files" test -e .run/app.env

# ---- 8. a busy port is refused BEFORE anything starts -------------------------------------
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
LISTENER_PID=$!
t_wait "a stand-in listener holds the HTTP port" 10 port_busy
run_setup up
t_ne "up refuses while the HTTP port is taken (non-zero exit)" "0" "$SETUP_RC"
t_match "the message names the port as in use" 'already in use' "$SETUP_OUT"
t_eq "nothing was started (no nextcloud container)" "0" "$(podman ps -a --format '{{.Names}}' | grep -c '^nextcloud-')"
kill "$LISTENER_PID" 2>/dev/null; wait "$LISTENER_PID" 2>/dev/null; LISTENER_PID=""

# ---- 9. legacy (non-Quadlet) containers are replaced; unrelated ones are not ----------------
podman run -d --name nextcloud-cron --label PODMAN_SYSTEMD_UNIT=podman-compose@nextcloud.service \
    "$(in_setup 'image_of helper')" sleep 600 >/dev/null
FOO=nextcloud-t07-unrelated
podman run -d --name "$FOO" "$(in_setup 'image_of helper')" sleep 600 >/dev/null
run_setup up
t_eq "up (reinstall) exits 0" "0" "$SETUP_RC"
t_match "the legacy compose-style container was reported removed" 'removed legacy container nextcloud-cron' "$SETUP_OUT"
t_eq "nextcloud-cron is now owned by its Quadlet unit" "nextcloud-cron.service" "$(podman inspect -f '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' nextcloud-cron)"
t_eq "an unrelated nextcloud-* container was NOT touched" "true" "$(podman inspect -f '{{.State.Running}}' "$FOO")"
podman rm -f "$FOO" >/dev/null 2>&1; FOO=""
t_wait "stack healthy after reinstall" 240 stack_healthy
t_eq "same Nextcloud instance after uninstall + up (instance id)" "$inst_before" "$(occ config:system:get instanceid | tr -d '\r\n')"
t_check "file still there after uninstall + reinstall" marker_same
t_eq "reinstall: no restart loop (NRestarts of app is 0 on a fresh start)" "0" "$(systemctl --user show -p NRestarts --value "$(t_unit app)")"

# ---- 10. bad configuration is refused, with a clear message, without touching the stack ------
ids_now="$(stack_ctr_ids)"
mk_env() {  # mk_env FILE sed-expression
    cp -p "$TMP/env.orig" "$1"; sed -i "$2" "$1"
}
mk_env "$TMP/rel.env" 's|^DATA_HOST_PATH=.*|DATA_HOST_PATH=relative/dir|'
mk_env "$TMP/ph.env"  's|^DB_PASSWORD=.*|DB_PASSWORD=change-me|'
for variant in rel ph; do
    out="$(NEXTCLOUD_ENV_FILE="$TMP/$variant.env" NEXTCLOUD_RUN_DIR="$TMP/run-$variant" NEXTCLOUD_QUADLET_DIR="$TMP/q-$variant" NEXTCLOUD_NO_RELOAD=1 "$T_ROOT/setup.sh" install 2>&1)"; rc=$?
    case "$variant" in
        rel) t_ne "install refuses a relative DATA_HOST_PATH" "0" "$rc"; t_match "message explains: absolute path required" 'must be an absolute path' "$out" ;;
        ph)  t_ne "install refuses the placeholder password 'change-me'" "0" "$rc"; t_match "message names the placeholder" "change-me" "$out" ;;
    esac
done
t_eq "refused installs did not touch the running stack" "$ids_now" "$(stack_ctr_ids)"
t_check "stack is still healthy at the end" stack_healthy

# ---- cleanup -----------------------------------------------------------------------------------
dav DELETE "$marker.txt" -o /dev/null
t_end
