#!/usr/bin/env bash
# ===========================================================================
#  t08-backup-restore — DESTRUCTIVE live drill.
#
#  Takes real backups, corrupts copies of them, restores onto the live volumes,
#  then destroys the whole instance, proves a plain `up` is refused (the data
#  directory is not empty), and restores from nothing. After every restore it
#  verifies identity (instance id), content (files, database rows, users),
#  credentials and — the point of this change set — file ownership.
#
#  The stack is healthy again at the end (also on failure: the EXIT trap starts
#  it). Backups created by this module are removed again.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t08-backup-restore "backup, restore, destroy, restore-from-nothing"

TMP="$(t_tmpdir)"
RUN="t08-$$-$(date +%s)"
ADMIN="$(nc_admin_user)"
DATA="$(data_dir)"
MYDIR="$DATA/$ADMIN/files/$RUN"
CREATED_BACKUPS=()
USERS_TO_DELETE=()

cleanup() {
    stack_healthy || "$T_ROOT/setup.sh" up >/dev/null 2>&1
    dav DELETE "$RUN" -o /dev/null 2>/dev/null
    local u b
    for u in "${USERS_TO_DELETE[@]:-}"; do [ -n "$u" ] && occ user:delete "$u" >/dev/null 2>&1; done
    for b in "${CREATED_BACKUPS[@]:-}"; do [ -n "$b" ] && [ -d "$b" ] && rm -rf -- "$b"; done
    rm -rf -- backups/99999999-999999
    _t_cleanup_tmp
}
trap cleanup EXIT

# ---- helpers (named functions: t_check runs them in this shell's subshell) -------------
put()        { dav PUT "$RUN/$1" -T "$2" -o /dev/null -w '%{http_code}'; }
get_is()     { dav GET "$RUN/$1" | cmp -s - "$2"; }
host_is()    { cmp -s "$MYDIR/$1" "$2"; }
exists_dav() { [ "$(dav GET "$RUN/$1" -o /dev/null -w '%{http_code}')" = 200 ]; }
gone_dav()   { [ "$(dav GET "$RUN/$1" -o /dev/null -w '%{http_code}')" = 404 ]; }
inst_id()    { occ config:system:get instanceid | tr -d '\r\n'; }
user_list()  { occ user:list --output=json 2>/dev/null; }
has_user()   { user_list | grep -q "\"$1\""; }
login_ok()   { [ "$(https_curl -u "$(nc_admin_user):$(nc_admin_pass)" -H 'OCS-APIRequest: true' -o /dev/null -w '%{http_code}' "https://127.0.0.1:$(nc_https_port)/ocs/v1.php/cloud/user?format=json")" = 200 ]; }
db_tables()  { podman exec nextcloud-db sh -c 'mariadb -N -u root -p"$MARIADB_ROOT_PASSWORD" -e "select count(*) from information_schema.tables where table_schema=\"$MARIADB_DATABASE\""' 2>/dev/null | tr -d '\r\n'; }
foreign_in_data()  { find "$DATA" -not -user "$(id -un)" 2>/dev/null | wc -l; }
foreign_in_vols()  {
    local v n=0 mp
    for v in $(in_setup 'echo $VOL_HTML $VOL_DB $VOL_REDIS $VOL_CADDY'); do
        mp="$(podman volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)" || continue
        n=$((n + $(podman unshare sh -c 'find "$1" -not -uid "$(id -u)" | wc -l' _ "$mp")))
    done
    echo "$n"
}
data_count() { find "$DATA" 2>/dev/null | wc -l; }
all_clean_ownership() {
    t_eq "ownership: no entry in the data directory belongs to another user" "0" "$(foreign_in_data)"
    t_eq "ownership: no file in any volume belongs to a sub-uid" "0" "$(foreign_in_vols)"
}
newest_dir() { ls -1d backups/*/ 2>/dev/null | sort | tail -1 | sed 's|/$||'; }

# ---- 0. fixtures: files (text, binary, unicode, nested), users --------------------------------
t_wait "precondition: the stack is healthy" 120 stack_healthy
INST="$(inst_id)"
t_match "instance id looks sane" '^[a-z0-9]{8,}$' "$INST"

printf 'A version ONE %s\n' "$RUN" > "$TMP/a1.txt"
printf 'A version TWO (changed after the backup) %s\n' "$RUN" > "$TMP/a2.txt"
head -c 1048576 /dev/urandom > "$TMP/bin.dat"
printf 'unicode name %s\n' "$RUN" > "$TMP/u.txt"
printf 'nested %s\n' "$RUN" > "$TMP/n.txt"
printf 'to be deleted after the backup %s\n' "$RUN" > "$TMP/del.txt"
printf 'created AFTER the backup %s\n' "$RUN" > "$TMP/b.txt"
t_eq "MKCOL fixture directory" "201" "$(dav MKCOL "$RUN" -o /dev/null -w '%{http_code}')"
t_eq "PUT a.txt"            "201" "$(put a.txt "$TMP/a1.txt")"
t_eq "PUT bin.dat (1 MiB)"  "201" "$(put bin.dat "$TMP/bin.dat")"
t_eq "PUT unicode name"     "201" "$(put 'ünï%20cödé%20ñ.txt' "$TMP/u.txt")"
t_eq "MKCOL nested"         "201" "$(dav MKCOL "$RUN/sub" -o /dev/null -w '%{http_code}')"
t_eq "PUT nested/deep.txt"  "201" "$(put sub/deep.txt "$TMP/n.txt")"
t_eq "PUT del.txt"          "201" "$(put del.txt "$TMP/del.txt")"

USER1="t08u1${RANDOM}"; USER2="t08u2${RANDOM}"
USERS_TO_DELETE=("$USER1" "$USER2")
add_user() { podman exec -e OC_PASS="T08-pass-$RANDOM-$RANDOM" -u "$(in_setup 'app_user')" nextcloud-app php /var/www/html/occ user:add --password-from-env --display-name="$1" "$1" >/dev/null 2>&1; }
t_check "create a Nextcloud user BEFORE the backup (database content)" add_user "$USER1"
t_check "that user exists" has_user "$USER1"
TABLES="$(db_tables)"
t_ge "database has a full Nextcloud schema" 100 "$TABLES"
BACKUPS_BEFORE="$(ls -1d backups/*/ 2>/dev/null | wc -l)"

# ---- 1. quiesced backup ------------------------------------------------------------------------------
run_setup backup --quiesce
t_eq "backup --quiesce exits 0" "0" "$SETUP_RC"
t_match "output says it entered maintenance mode" 'maintenance mode on' "$SETUP_OUT"
t_match "output says it left maintenance mode" 'maintenance mode off' "$SETUP_OUT"
BK="$(newest_dir)"; CREATED_BACKUPS+=("$BK")
t_check "backup directory exists" test -d "$BK"
t_eq "backup directory is mode 0700" "700" "$(stat -c %a "$BK")"
for f in database.sql.gz data.tar.gz config.tar.gz env.backup; do t_check "backup contains $f" test -s "$BK/$f"; done
t_eq "env.backup is mode 0600" "600" "$(stat -c %a "$BK/env.backup")"
t_check "systemd.backup holds the unit templates" test -f "$BK/systemd.backup/nextcloud-app.container.in"
t_check "database.sql.gz is a valid gzip" gzip -t "$BK/database.sql.gz"
t_check "data.tar.gz is a valid archive" tar tzf "$BK/data.tar.gz"
t_match "database dump contains the schema" 'CREATE TABLE' "$(zcat "$BK/database.sql.gz" | grep -m1 'CREATE TABLE')"
t_check "database dump contains the user created before the backup" bash -c "zcat '$BK/database.sql.gz' | grep -q '$USER1'"
t_check "data archive contains the fixture file" bash -c "tar tzf '$BK/data.tar.gz' | grep -q '/$RUN/a.txt'"
t_match "config archive contains config/config.php (instanceid, secret, salt)" 'config/config\.php' "$(tar tzf "$BK/config.tar.gz")"
t_match "maintenance mode is OFF after the backup" 'disabled' "$(occ maintenance:mode)"
# Regression: Nextcloud keeps the maintenance flag in config.php. A config archived AFTER entering
# maintenance mode restored an instance stuck in maintenance mode.
cfg_in_backup() { tar xzOf "$BK/config.tar.gz" config/config.php; }
t_check "the config.php inside the quiesced backup was captured before maintenance mode began" cfg_in_backup
t_check_not "…and is NOT flagged 'maintenance' => true" bash -c "tar xzOf '$BK/config.tar.gz' config/config.php | grep -q \"'maintenance' => true\""
t_check "stack healthy after the backup" stack_healthy

# ---- 2. mutate everything after the backup ---------------------------------------------------------------
t_eq "overwrite a.txt" "204" "$(put a.txt "$TMP/a2.txt")"
t_eq "add b.txt (did not exist at backup time)" "201" "$(put b.txt "$TMP/b.txt")"
t_eq "delete del.txt" "204" "$(dav DELETE "$RUN/del.txt" -o /dev/null -w '%{http_code}')"
t_check "create a second user AFTER the backup" add_user "$USER2"
t_check "mutation visible: a.txt is version TWO" get_is a.txt "$TMP/a2.txt"
t_check "mutation visible: b.txt exists" exists_dav b.txt
t_check "mutation visible: del.txt gone" gone_dav del.txt

# ---- 3. bad backups are refused BEFORE anything is touched -------------------------------------------------
snap_before="$(data_count)"; ids_before="$(stack_ctr_ids)"
mk_bad() { rm -rf "$TMP/bad"; cp -a "$BK" "$TMP/bad"; }
mk_bad; head -c 100000 "$BK/data.tar.gz" > "$TMP/bad/data.tar.gz"
run_setup_confirm RESTORE restore "$TMP/bad"
t_ne "truncated data.tar.gz: restore refuses (non-zero)" "0" "$SETUP_RC"
t_match "…and names the corrupt archive" 'corrupt|not a readable' "$SETUP_OUT"
mk_bad; rm -f "$TMP/bad/env.backup"
run_setup_confirm RESTORE restore "$TMP/bad"
t_ne "missing env.backup: restore refuses" "0" "$SETUP_RC"
t_match "…saying the set is incomplete" 'not a complete backup set' "$SETUP_OUT"
mk_bad; mkdir -p "$TMP/cfg/config"; echo x > "$TMP/cfg/config/other.php"; tar czf "$TMP/bad/config.tar.gz" -C "$TMP/cfg" config
run_setup_confirm RESTORE restore "$TMP/bad"
t_ne "config archive without config.php: restore refuses" "0" "$SETUP_RC"
t_match "…explaining config.php is required" 'config\.php' "$SETUP_OUT"
run_setup_confirm no restore "$BK"
t_ne "wrong confirmation word: aborted" "0" "$SETUP_RC"
t_match "…and says nothing was restored" 'nothing was restored' "$SETUP_OUT"
run_setup_confirm RESTORE restore "$TMP/does-not-exist"
t_ne "non-existent backup directory is refused" "0" "$SETUP_RC"
t_eq "all refusals left the data directory untouched (entry count)" "$snap_before" "$(data_count)"
t_eq "…and did not recreate any container" "$ids_before" "$(stack_ctr_ids)"
t_check "…and the mutated state is still there (a.txt is still version TWO)" get_is a.txt "$TMP/a2.txt"

# ---- 4. newest_backup chooses the newest COMPLETE set; a failed backup leaves nothing ---------------------------
mkdir -p backups/99999999-999999; cp "$BK/database.sql.gz" backups/99999999-999999/
t_eq "an incomplete newer directory is ignored by newest_backup" "$BK" "$(in_setup 'newest_backup')"
rm -rf backups/99999999-999999
n_before="$(ls -1d backups/*/ | wc -l)"
systemctl --user stop "$(t_unit db)" 2>/dev/null
run_setup backup
t_ne "backup with the database down fails" "0" "$SETUP_RC"
t_eq "…and leaves no partial backup directory behind" "$n_before" "$(ls -1d backups/*/ | wc -l)"
run_setup up
t_wait "stack healthy again after the failed-backup experiment" 240 stack_healthy

# ---- 5. restore onto the LIVE volumes ------------------------------------------------------------------------------
run_setup_confirm RESTORE restore "$BK"
t_eq "restore exits 0" "0" "$SETUP_RC"
t_match "archives were verified first" 'backup archives verified' "$SETUP_OUT"
t_match "the previous .env was saved" 'previous \.env saved as' "$SETUP_OUT"
t_match "restore completed" 'Restore complete' "$SETUP_OUT"
t_wait "stack healthy after the restore" 240 stack_healthy
t_match "the restored instance is NOT in maintenance mode" 'disabled' "$(occ maintenance:mode)"
t_eq "SAME Nextcloud instance (instance id from the restored config.php)" "$INST" "$(inst_id)"
t_check "a.txt is back to version ONE (API)" get_is a.txt "$TMP/a1.txt"
t_check "a.txt is version ONE on the host disk" host_is a.txt "$TMP/a1.txt"
t_check "bin.dat restored byte-identical" get_is bin.dat "$TMP/bin.dat"
t_check "nested file restored" get_is sub/deep.txt "$TMP/n.txt"
t_check "del.txt is back" get_is del.txt "$TMP/del.txt"
t_check "b.txt (created after the backup) is gone" gone_dav b.txt
t_check "the user created before the backup exists" has_user "$USER1"
t_check_not "the user created after the backup is gone" has_user "$USER2"
t_eq "database has the same number of tables" "$TABLES" "$(db_tables)"
t_check "the administrator can log in with the credentials from the backup" login_ok
t_check "a saved copy of the previous .env exists (mode 0600)" bash -c "ls .env.pre-restore.* >/dev/null 2>&1 && [ \"\$(stat -c %a \$(ls -t .env.pre-restore.* | head -1))\" = 600 ]"
all_clean_ownership
t_match "status reports ownership ok" '0 entries not owned' "$("$T_ROOT/setup.sh" status 2>&1)"

# ---- 6. plain backup, then the full drill: destroy -> up refused -> restore from nothing -------------------------
run_setup backup
t_eq "plain backup exits 0" "0" "$SETUP_RC"
BK2="$(newest_dir)"; CREATED_BACKUPS+=("$BK2")
t_ne "the second backup is a different directory" "$BK" "$BK2"
t_check "the second backup is a complete set" in_setup "backup_complete '$PWD/$BK2'"
t_nomatch "plain backup does not touch maintenance mode" 'maintenance mode' "$SETUP_OUT"

run_setup_confirm DELETE destroy
t_eq "destroy exits 0" "0" "$SETUP_RC"
t_eq "destroy: no nextcloud container remains" "0" "$(podman ps -a --format '{{.Names}}' | grep -c '^nextcloud-')"
vols_left=0; for v in $(in_setup 'echo $VOL_HTML $VOL_DB $VOL_REDIS $VOL_CADDY'); do podman volume exists "$v" && vols_left=$((vols_left + 1)); done
t_eq "destroy: all four named volumes are gone" "0" "$vols_left"
t_check_not "destroy: the network is gone" podman network exists "$(in_setup 'echo $NETWORK_NAME')"
t_check "destroy never deletes the user data directory" test -f "$MYDIR/a.txt"
t_check "destroy keeps .env" test -f .env

run_setup up
t_ne "up after destroy is REFUSED while the data directory is not empty" "0" "$SETUP_RC"
t_match "…with a clear explanation" 'data directory is not empty' "$SETUP_OUT"
t_eq "…and started nothing" "0" "$(podman ps -a --format '{{.Names}}' | grep -c '^nextcloud-')"

run_setup_confirm RESTORE restore "$BK2"
t_eq "restore from nothing exits 0" "0" "$SETUP_RC"
t_wait "stack healthy after restore-from-nothing" 300 stack_healthy
t_eq "SAME instance id after destroy + restore" "$INST" "$(inst_id)"
t_check "a.txt is version ONE" get_is a.txt "$TMP/a1.txt"
t_check "bin.dat byte-identical" get_is bin.dat "$TMP/bin.dat"
t_check "the user from the backup exists" has_user "$USER1"
t_check "administrator login works" login_ok
t_eq "database has the same number of tables" "$TABLES" "$(db_tables)"
all_clean_ownership
t_check "cron is running again" systemctl --user is-active --quiet "$(t_unit cron)"
app_healthy() { [ "$(podman inspect -f '{{.State.Health.Status}}' nextcloud-app)" = healthy ]; }
# The healthcheck runs every 30 s, so a freshly started container is 'starting' for a while.
t_wait "app container reports healthy (its healthcheck passes)" 150 app_healthy

t_end
