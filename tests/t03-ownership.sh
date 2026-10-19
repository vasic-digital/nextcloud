#!/usr/bin/env bash
# t03-ownership: every process and every file of the stack belongs to the invoking user.
# Only touches uniquely named temp entries that it removes itself.
. "$(dirname "$0")/lib.sh"
t_begin t03 "ownership: processes and files belong to the invoking user"

ME="$(id -u)"; MEG="$(id -g)"
SVCS=(db redis app cron caddy)
DATA="$(data_dir)"
ADMIN="$(nc_admin_user)"
VOLS=(nextcloud-html nextcloud-db nextcloud-redis nextcloud-caddy-data)
UNS_ME="$(podman unshare id -u)"      # the invoking user as seen inside Podman's user namespace
UNS_MEG="$(podman unshare id -g)"
t_match "invoking uid is numeric and non-zero" '^[1-9][0-9]*$' "$ME"
t_match "uid inside the user namespace is numeric" '^[0-9]+$' "$UNS_ME"

# ---- processes ---------------------------------------------------------------------
# podman top prints "<host uid> <container user> <pid> <args>" (header first).
top_of() {
    # A process that exits while podman reads /proc shows up as "?" (huser unknown,
    # args "[name]"). Re-sample until a snapshot has none; a snapshot is never edited.
    # Waits up to 60 s: crond runs `php cron.php` every five minutes and that job
    # can take a while to finish.
    local i out
    for i in $(seq 1 60); do
        out="$(podman top "nextcloud-$1" huser user pid args 2>/dev/null | tail -n +2)"
        printf '%s\n' "$out" | awk '$1 == "?"{f=1} END{exit f}' && break
        sleep 1
    done
    printf '%s\n' "$out"
}
for s in db redis app caddy; do
    rows="$(top_of $s)"
    n="$(printf '%s\n' "$rows" | grep -c .)"
    bad="$(printf '%s\n' "$rows" | awk -v me="$ME" 'NF && $1 != me')"
    t_ge "nextcloud-$s has running processes" 1 "$n"
    t_eq "every process of nextcloud-$s runs as host uid $ME" "" "$bad"
done
rows="$(top_of caddy)"
t_match "caddy's container-root maps to the invoking uid" "^$ME +root +[0-9]+ +caddy run" "$(printf '%s\n' "$rows" | head -1)"

# cron: the single documented exception, kept as narrow as possible.
rows="$(top_of cron)"
t_ge "nextcloud-cron has running processes" 2 "$(printf '%s\n' "$rows" | grep -c .)"
foreign="$(printf '%s\n' "$rows" | awk -v me="$ME" 'NF && $1 != me')"
t_ne "cron has its documented sub-uid supervisor processes (exception is exercised)" "" "$foreign"
t_eq "cron: every non-invoking process is container-root running /run/podman-init or busybox crond" "" \
    "$(printf '%s\n' "$foreign" | awk 'NF && !($2 == "root" && ($4 ~ /^\/run\/podman-init/ || ($4 == "busybox" && $5 == "crond")))')"
t_eq "cron: no process runs as host root (uid 0)" "" "$(printf '%s\n' "$rows" | awk 'NF && $1 == 0')"
t_eq "cron: the exception covers one sub-uid only" "1" "$(printf '%s\n' "$foreign" | awk 'NF{print $1}' | sort -u | grep -c .)"
t_eq "cron: all job children (everything but init/crond) run as the invoking uid" "" \
    "$(printf '%s\n' "$rows" | awk -v me="$ME" 'NF && !($4 ~ /^\/run\/podman-init/ || ($4 == "busybox" && $5 == "crond")) && $1 != me')"
t_check_not "negative control: the exception filter would flag a non-root process in a sub-uid" \
    bash -c 'printf "100999 www-data 5 apache2 -D\n" | awk '"'"'NF && !($2 == "root" && ($4 ~ /^\/run\/podman-init/))'"'"' | grep -q . && exit 1 || exit 0'

# ---- user-namespace ids equal the image's real account ids ---------------------------
ns_of() { podman inspect "nextcloud-$1" --format '{{index .Config.Annotations "io.podman.annotations.userns"}}'; }
declare -A IMG=([app]=nextcloud [cron]=nextcloud [db]=db [redis]=redis)
declare -A ACC=(
    [app]="$(in_setup 'app_user' 2>/dev/null)"
    [cron]="$(in_setup 'app_user' 2>/dev/null)"
    [db]="$(in_setup 'env_or DB_RUN_USER "$DEFAULT_DB_RUN_USER"' 2>/dev/null)"
    [redis]="$(in_setup 'env_or REDIS_RUN_USER "$DEFAULT_REDIS_RUN_USER"' 2>/dev/null)")
for s in app cron db redis; do
    image="$(in_setup "image_of ${IMG[$s]}" 2>/dev/null)"
    t_ne "account name for $s resolved" "" "${ACC[$s]}"
    ids="$(podman run --rm --pull=never --entrypoint sh "$image" -c "id -u ${ACC[$s]}; id -g ${ACC[$s]}" 2>/dev/null | tr '\n' ' ')"
    iu="${ids%% *}"; ig="${ids#* }"; ig="${ig%% *}"
    t_match "image $s: account ${ACC[$s]} ids read from the image" '^[0-9]+ [0-9]+ $' "$ids"
    t_eq "nextcloud-$s UserNS ids equal the image account's ids" "keep-id:uid=$iu,gid=$ig" "$(ns_of $s)"
done
t_check_not "negative control: a wrong account name does not resolve in the image" \
    podman run --rm --pull=never --entrypoint sh "$(in_setup 'image_of redis')" -c 'id -u no-such-account-$$'

# ---- host files -----------------------------------------------------------------------
tree_check() {  # label path min_entries
    local label="$1" p="$2" min="$3" total badu badg
    if [ ! -e "$p" ]; then t_fail "$label exists ($p)"; return; fi
    total="$(find "$p" 2>/dev/null | wc -l)"
    badu="$(find "$p" -not -user "$ME" 2>/dev/null | wc -l)"
    badg="$(find "$p" -not -group "$MEG" 2>/dev/null | wc -l)"
    t_ge "$label holds at least $min entries (tree is not trivially empty)" "$min" "$total"
    t_eq "$label: entries not owned by uid $ME" 0 "$badu"
    t_eq "$label: entries not in group gid $MEG" 0 "$badg"
}
tree_check "data dir" "$DATA" 5
tree_check ".run" "$T_ROOT/.run" 3
tree_check "tls" "$T_ROOT/tls" 2
tree_check "backups" "$T_ROOT/backups" 1
qd="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
q_total="$(find "$qd" -maxdepth 1 -name 'nextcloud*' 2>/dev/null | wc -l)"
t_ge "Quadlet files present" 6 "$q_total"
t_eq "Quadlet files not owned by uid $ME" 0 "$(find "$qd" -maxdepth 1 -name 'nextcloud*' -not -user "$ME" | wc -l)"
t_check_not "negative control: find -not -user detects a different owner (uid $((ME+1)) check on a tree we own)" \
    bash -c '[ "$(find "$1" -not -user "$2" 2>/dev/null | wc -l)" -eq 0 ]' _ "$T_ROOT/tls" "$((ME+1))"

# ---- volumes (inside the user namespace, where the invoking user is $UNS_ME) --------------
for v in "${VOLS[@]}"; do
    mp="$(podman volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)"
    t_ne "volume $v has a mountpoint" "" "$mp"
    t_ge "volume $v holds entries" 1 "$(podman unshare find "$mp" 2>/dev/null | wc -l)"
    t_eq "volume $v: entries not owned by the invoking user" 0 "$(podman unshare find "$mp" -not -uid "$UNS_ME" 2>/dev/null | wc -l)"
    t_eq "volume $v: entries not in the invoking user's group" 0 "$(podman unshare find "$mp" -not -gid "$UNS_MEG" 2>/dev/null | wc -l)"
done
hmp="$(podman volume inspect -f '{{.Mountpoint}}' nextcloud-html)"
t_check "html volume has the 'data' mount-point directory" podman unshare test -d "$hmp/data"
t_eq "html volume's data mount-point is owned by the invoking user" "$UNS_ME" "$(podman unshare stat -c %u "$hmp/data" 2>/dev/null)"

# ---- foreign_owned: positive and negative controls ------------------------------------------
fo_p() { export P="$1"; in_setup 'foreign_owned "$P"' >/dev/null 2>&1; }
t_check_not "foreign_owned is false for the data dir" fo_p "$DATA"
for v in "${VOLS[@]}"; do
    t_check_not "foreign_owned is false for volume $v" fo_p "$(podman volume inspect -f '{{.Mountpoint}}' "$v")"
done
base="$(t_tmpdir)"
FOREIGN="$base/foreign-$$"; OWN="$base/own-$$"
cleanup_foreign() { podman unshare rm -rf -- "$FOREIGN" "$OWN" 2>/dev/null; }
trap 'cleanup_foreign; _t_cleanup_tmp' EXIT
podman unshare mkdir "$FOREIGN" "$OWN"
podman unshare chown 1:1 "$FOREIGN"
t_ne "negative control prepared: the temp dir really has a sub-uid owner on the host" "$ME" "$(stat -c %u "$FOREIGN")"
t_check "foreign_owned is TRUE for a deliberately foreign-owned tree" fo_p "$FOREIGN"
t_check_not "foreign_owned is false for a tree created by the user itself" fo_p "$OWN"
cleanup_foreign
t_check_not "the temporary foreign tree was removed" test -e "$FOREIGN"

# ---- write-through: host <-> container -------------------------------------------------------
W="$DATA/$ADMIN/files/.t03-ownership-$$"
cleanup_w() { rm -rf -- "$W" 2>/dev/null; podman exec nextcloud-app rm -rf -- "/var/www/html/data/$ADMIN/files/.t03-ownership-$$" 2>/dev/null; }
trap 'cleanup_foreign; cleanup_w; _t_cleanup_tmp' EXIT
CW="/var/www/html/data/$ADMIN/files/.t03-ownership-$$"
t_check "admin files dir exists on the host" test -d "$DATA/$ADMIN/files"
# host -> container
mkdir "$W" && echo host > "$W/from-host.txt" && mkdir "$W/hostdir"
t_eq "host-created file belongs to the invoking user" "$ME:$MEG" "$(stat -c %u:%g "$W/from-host.txt")"
t_eq "container (www-data) sees the host file as its own account's uid" "$(podman exec nextcloud-app id -u)" "$(podman exec nextcloud-app stat -c %u "$CW/from-host.txt")"
t_check "container modifies the host-created file" podman exec nextcloud-app sh -c "echo container >> '$CW/from-host.txt'"
t_eq "the host sees the container's modification" "host container" "$(tr '\n' ' ' < "$W/from-host.txt" | sed 's/ $//')"
t_check "container creates a file inside the host-created dir" podman exec nextcloud-app sh -c "echo x > '$CW/hostdir/inner.txt'"
t_check "container deletes the host-created file" podman exec nextcloud-app rm -f "$CW/from-host.txt"
t_check_not "the host file is gone after the container deleted it" test -e "$W/from-host.txt"
t_check "container removes the host-created dir (with its content)" podman exec nextcloud-app rm -rf "$CW/hostdir"
t_check_not "the host dir is gone" test -e "$W/hostdir"
# container -> host
t_check "container creates a file and a dir" podman exec nextcloud-app sh -c "echo from-container > '$CW/from-container.txt' && mkdir '$CW/cdir' && echo y > '$CW/cdir/f'"
t_eq "container-created file is owned by the invoking user on the host" "$ME:$MEG" "$(stat -c %u:%g "$W/from-container.txt" 2>/dev/null)"
t_eq "container-created dir is owned by the invoking user on the host" "$ME:$MEG" "$(stat -c %u:%g "$W/cdir" 2>/dev/null)"
t_eq "container-created nested file is owned by the invoking user" "$ME:$MEG" "$(stat -c %u:%g "$W/cdir/f" 2>/dev/null)"
t_check "host modifies the container-created file" bash -c "echo host-edit >> '$W/from-container.txt'"
t_check "container reads the host's edit" bash -c "[ \"\$(podman exec nextcloud-app cat '$CW/from-container.txt' | tr '\n' ' ')\" = 'from-container host-edit ' ]"
t_check "host deletes the container-created file and dir" rm -rf "$W/from-container.txt" "$W/cdir"
t_check_not "container no longer sees the deleted entries" podman exec nextcloud-app sh -c "test -e '$CW/from-container.txt' -o -e '$CW/cdir'"
rm -rf "$W"
t_check_not "temporary write-through dir removed" test -e "$W"

# ---- setup.sh status ------------------------------------------------------------------------------
st="$(./setup.sh status 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
own="$(printf '%s\n' "$st" | sed -n '/Ownership/,/Host tuning\|Health/p')"
t_match "status prints the Ownership section" 'Ownership \(everything should belong to' "$own"
t_match "status: data dir reports 0 entries not owned" '\(0 entries not owned by' "$own"
t_nomatch "status: no volume reports foreign-owned files" 'foreign-owned' "$own"
t_eq "status: all four volumes report ok" 4 "$(printf '%s\n' "$own" | grep -cE '^ +nextcloud-[a-z-]+ +ok$')"

t_end
