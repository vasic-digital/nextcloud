#!/usr/bin/env bash
# ===========================================================================
#  t06-nextcloud: functional checks of the live Nextcloud through HTTPS
#  (WebDAV + OCS as the .env admin), host-disk consistency, Redis, MariaDB,
#  the hook-applied settings and -- slowly, once -- the background-job cron.
#
#  Only writes: one unique collection under the admin's files, always removed
#  (WebDAV and host disk) on exit.   T_QUICK=1 skips the ~5 minute cron wait.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t06-nextcloud "Nextcloud functional: WebDAV, OCS, host disk, Redis, DB, cron"

USER_="$(nc_admin_user)"; PASS_="$(nc_admin_pass)"
PORT="$(nc_https_port)"; DATA="$(data_dir)"
BASE="https://127.0.0.1:$PORT"
if [ -z "$USER_" ] || [ -z "$PASS_" ] || [ -z "$PORT" ] || [ -z "$DATA" ]; then
    t_fail "prerequisites: admin user/password, HTTPS port and DATA_HOST_PATH resolve from .env"
    t_end; exit $?
fi

NL=$'\n'
occ() { ./setup.sh occ "$@" </dev/null 2>&1; }
TMP="$(t_tmpdir)"
COLL="t06-$$-$RANDOM"
HOSTDIR="$DATA/$USER_/files/$COLL"

cleanup() {
    dav DELETE "$COLL" -o /dev/null >/dev/null 2>&1
    [ -d "$HOSTDIR" ] && rm -rf -- "$HOSTDIR" 2>/dev/null
    _t_cleanup_tmp
}
trap cleanup EXIT
trap 'echo; echo interrupted; exit 130' INT TERM

code() { dav "$@" -o /dev/null -w '%{http_code}'; }                # METHOD PATH [args]
sha()  { sha256sum | cut -d' ' -f1; }
etag_of() { dav GET "$1" -D - -o /dev/null | tr -d '\r' | sed -n 's/^[Ee][Tt]ag: *//p' | head -1; }
# list the collection (depth 1): "name length" lines, names URL-decoded
listing() {
    dav PROPFIND "$1" -H 'Depth: 1' --data '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>' |
    python3 -c '
import sys,urllib.parse,xml.etree.ElementTree as E
ns={"d":"DAV:"}
for r in E.fromstring(sys.stdin.read()).findall("d:response",ns):
    h=urllib.parse.unquote(r.find("d:href",ns).text).rstrip("/").rsplit("/",1)[-1]
    l=r.find(".//d:getcontentlength",ns)
    print(h, l.text if l is not None else "-")'
}

# ======================= instance health (occ, status.php) =====================
st="$(curl -sS --max-time 20 --cacert "$T_ROOT/tls/site.crt" "$BASE/status.php")"
t_match "status.php: installed=true"       '"installed":true'      "$st"
t_match "status.php: maintenance=false"    '"maintenance":false'   "$st"
t_match "status.php: needsDbUpgrade=false" '"needsDbUpgrade":false' "$st"
t_match "occ status: installed" 'installed: true' "$(occ status)"
t_eq "background jobs mode is cron (app config)" cron "$(occ config:app:get core backgroundjobs_mode)"
scan="$(occ files:scan "$USER_")"; src=$?
t_check "occ files:scan <admin> exits 0" test "$src" -eq 0
t_match "occ files:scan <admin> reports Errors = 0" '\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*\| 0 +\|' "$scan"
occ integrity:check-core >"$TMP/integrity" 2>&1; irc=$?
if [ "$irc" -eq 0 ]; then t_pass "occ integrity:check-core exits 0 (no tampered/extra core files)" "$(cat "$TMP/integrity")"
else t_fail "occ integrity:check-core exits 0" "rc=$irc $(head -c 600 "$TMP/integrity")"; fi
t_eq "filesystem_check_changes = 1 (hook applied)" 1 "$(occ config:system:get filesystem_check_changes)"
t_eq "maintenance_window_start = NEXTCLOUD_MAINTENANCE_WINDOW_START" "$(cfg NEXTCLOUD_MAINTENANCE_WINDOW_START 1)" "$(occ config:system:get maintenance_window_start)"
t_eq "lost_password_link = disabled (hook applied)" disabled "$(occ config:system:get lost_password_link)"

# ======================= WebDAV lifecycle ==========================================
t_eq "MKCOL working collection -> 201" 201 "$(code MKCOL "$COLL")"
t_eq "MKCOL again -> 405 (already exists)" 405 "$(code MKCOL "$COLL")"

printf 'hello nextcloud\n' >"$TMP/t.txt"
t_eq "PUT text file -> 201" 201 "$(code PUT "$COLL/hello.txt" --data-binary @"$TMP/t.txt")"
t_eq "GET text file returns identical bytes" "$(sha <"$TMP/t.txt")" "$(dav GET "$COLL/hello.txt" | sha)"

head -c $((1024 * 1024)) /dev/urandom >"$TMP/1m.bin"
t_eq "PUT 1 MiB random binary -> 201" 201 "$(code PUT "$COLL/one.bin" --data-binary @"$TMP/1m.bin")"
t_eq "GET 1 MiB binary: sha256 matches" "$(sha <"$TMP/1m.bin")" "$(dav GET "$COLL/one.bin" | sha)"

lst="$(listing "$COLL")"
t_match "PROPFIND depth 1 lists hello.txt with correct getcontentlength" "(^|$NL)hello\.txt $(stat -c %s "$TMP/t.txt")($|$NL)" "$lst"
t_match "PROPFIND depth 1 lists one.bin with correct getcontentlength"  "(^|$NL)one\.bin 1048576($|$NL)" "$lst"

e1="$(etag_of "$COLL/hello.txt")"
t_match "GET returns an ETag" '^"?[0-9a-f]+' "$e1"
printf 'second version, longer\n' >"$TMP/t2.txt"
t_eq "PUT overwrite -> 204" 204 "$(code PUT "$COLL/hello.txt" --data-binary @"$TMP/t2.txt")"
t_eq "GET after overwrite shows the new content" "$(sha <"$TMP/t2.txt")" "$(dav GET "$COLL/hello.txt" | sha)"
e2="$(etag_of "$COLL/hello.txt")"
t_ne "ETag changed after overwrite" "$e1" "$e2"

c304="$(dav GET "$COLL/hello.txt" -H "If-None-Match: $e2" -o /dev/null -w '%{http_code}')"
t_eq "conditional GET with the current ETag -> 304" 304 "$c304"
t_eq "conditional GET with a stale ETag -> 200" 200 "$(dav GET "$COLL/hello.txt" -H "If-None-Match: $e1" -o /dev/null -w '%{http_code}')"

rg="$(dav GET "$COLL/one.bin" -H 'Range: bytes=0-9' -o "$TMP/range" -w '%{http_code}')"
t_eq "Range GET -> 206" 206 "$rg"
t_eq "Range GET returns exactly 10 bytes" 10 "$(stat -c %s "$TMP/range")"
t_eq "Range GET bytes equal the first 10 bytes of the file" "$(head -c 10 "$TMP/1m.bin" | sha)" "$(sha <"$TMP/range")"

head -c $((8 * 1024 * 1024)) /dev/urandom >"$TMP/8m.bin"
t_eq "PUT 8 MiB -> 201" 201 "$(code PUT "$COLL/big.bin" --data-binary @"$TMP/8m.bin")"
t_eq "GET 8 MiB round trip sha256 matches" "$(sha <"$TMP/8m.bin")" "$(dav GET "$COLL/big.bin" | sha)"

UNI='tëst ünï ✓ file.txt'
ENC="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$UNI")"
printf 'unicode payload\n' >"$TMP/u.txt"
t_eq "PUT unicode+space name (percent-encoded) -> 201" 201 "$(code PUT "$COLL/$ENC" --data-binary @"$TMP/u.txt")"
t_eq "GET unicode+space name round-trips" "$(sha <"$TMP/u.txt")" "$(dav GET "$COLL/$ENC" | sha)"
t_match "PROPFIND lists the decoded unicode name" "$UNI" "$(listing "$COLL")"

DST="$BASE/remote.php/dav/files/$USER_/$COLL"
t_eq "COPY one.bin -> copy.bin -> 201" 201 "$(code COPY "$COLL/one.bin" -H "Destination: $DST/copy.bin")"
t_eq "COPY result identical to source" "$(sha <"$TMP/1m.bin")" "$(dav GET "$COLL/copy.bin" | sha)"
t_eq "MOVE copy.bin -> moved.bin -> 201" 201 "$(code MOVE "$COLL/copy.bin" -H "Destination: $DST/moved.bin")"
t_eq "source of MOVE is gone (404)" 404 "$(code GET "$COLL/copy.bin")"
t_eq "GET moved file identical to original" "$(sha <"$TMP/1m.bin")" "$(dav GET "$COLL/moved.bin" | sha)"

# ---- host disk view ----------------------------------------------------------------
t_check "hello.txt exists on the host disk at the expected path" test -f "$HOSTDIR/hello.txt"
t_eq "host file sha256 equals the uploaded content" "$(sha <"$TMP/t2.txt")" "$(sha <"$HOSTDIR/hello.txt" 2>/dev/null)"
t_eq "host file owner is the invoking user" "$(me_user)" "$(stat -c %U "$HOSTDIR/hello.txt" 2>/dev/null)"
t_eq "host 8 MiB file sha256 equals the uploaded content" "$(sha <"$TMP/8m.bin")" "$(sha <"$HOSTDIR/big.bin" 2>/dev/null)"
t_check "unicode+space file exists on the host disk" test -f "$HOSTDIR/$UNI"
t_eq "host directory owner is the invoking user" "$(me_user)" "$(stat -c %U "$HOSTDIR" 2>/dev/null)"

# host-side append is seen through WebDAV (filesystem_check_changes=1)
printf 'appended on host\n' >>"$HOSTDIR/hello.txt"
listing "$COLL" >/dev/null
cat "$TMP/t2.txt" >"$TMP/t3.txt"; printf 'appended on host\n' >>"$TMP/t3.txt"
t_eq "host-side append is visible via WebDAV GET after a PROPFIND of the parent" "$(sha <"$TMP/t3.txt")" "$(dav GET "$COLL/hello.txt" | sha)"
t_match "PROPFIND reports the new size of the host-modified file" "(^|$NL)hello\.txt $(stat -c %s "$TMP/t3.txt")($|$NL)" "$(listing "$COLL")"
# host-side delete disappears
rm -f -- "$HOSTDIR/moved.bin"
t_nomatch "host-side delete disappears from PROPFIND" "(^|$NL)moved\.bin " "$(listing "$COLL")"
t_eq "host-deleted file gives 404 via WebDAV" 404 "$(code GET "$COLL/moved.bin")"
# host-side create appears
printf 'made on host\n' >"$HOSTDIR/fromhost.txt"
t_match "host-side created file appears in PROPFIND" "(^|$NL)fromhost\.txt " "$(listing "$COLL")"
t_eq "host-created file readable through WebDAV" "$(printf 'made on host\n' | sha)" "$(dav GET "$COLL/fromhost.txt" | sha)"

# ---- delete -------------------------------------------------------------------------------
t_eq "DELETE a file -> 204" 204 "$(code DELETE "$COLL/hello.txt")"
t_eq "GET deleted file -> 404" 404 "$(code GET "$COLL/hello.txt")"
t_check_not "deleted file is gone from the host disk" test -e "$HOSTDIR/hello.txt"
t_eq "DELETE the working directory -> 204" 204 "$(code DELETE "$COLL")"
t_eq "GET inside the deleted directory -> 404" 404 "$(code GET "$COLL/one.bin")"
t_eq "PROPFIND on the deleted directory -> 404" 404 "$(code PROPFIND "$COLL" -H 'Depth: 0')"
t_check_not "deleted directory is gone from the host disk" test -e "$HOSTDIR"

# ======================= auth / error sanity ================================================
t_eq "PROPFIND on a non-existing path -> 404" 404 "$(code PROPFIND "no-such-$$-$RANDOM" -H 'Depth: 0')"
t_eq "PUT without authentication -> 401" 401 "$(https_curl -X PUT --data x -o /dev/null -w '%{http_code}' "$BASE/remote.php/dav/files/$USER_/t06-noauth-$$.txt")"
t_check_not "unauthenticated PUT did not create a file" test -e "$DATA/$USER_/files/t06-noauth-$$.txt"
t_eq "PROPFIND with a wrong password -> 401" 401 "$(https_curl -u "$USER_:wrong-$RANDOM-$RANDOM" -X PROPFIND -o /dev/null -w '%{http_code}' "$BASE/remote.php/dav/files/$USER_/")"

# ======================= OCS ====================================================================
ocs() { https_curl -H 'OCS-APIRequest: true' "$@"; }
caps="$(ocs -u "$USER_:$PASS_" "$BASE/ocs/v1.php/cloud/capabilities?format=json")"
t_eq "OCS capabilities: meta.status = ok" ok "$(python3 -c 'import sys,json;print(json.load(sys.stdin)["ocs"]["meta"]["status"])' <<<"$caps" 2>/dev/null)"
major="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["ocs"]["data"]["version"]["major"])' <<<"$caps" 2>/dev/null)"
t_ge "OCS capabilities: server major version >= 35" 35 "${major:-0}"
who="$(ocs -u "$USER_:$PASS_" "$BASE/ocs/v2.php/cloud/user?format=json")"
t_eq "OCS cloud/user returns the admin id" "$USER_" "$(python3 -c 'import sys,json;print(json.load(sys.stdin)["ocs"]["data"]["id"])' <<<"$who" 2>/dev/null)"
t_eq "OCS with a wrong password -> 401" 401 "$(ocs -u "$USER_:wrong-$RANDOM-$RANDOM" -o /dev/null -w '%{http_code}' "$BASE/ocs/v2.php/cloud/user?format=json")"
t_eq "OCS without authentication -> 401" 401 "$(ocs -o /dev/null -w '%{http_code}' "$BASE/ocs/v2.php/cloud/user?format=json")"

# ======================= Redis ====================================================================
t_match "memcache.distributed is a Redis class" 'Redis' "$(occ config:system:get memcache.distributed)"
t_match "memcache.locking is a Redis class"     'Redis' "$(occ config:system:get memcache.locking)"
t_eq "redis answers PING from its container" PONG "$(podman exec nextcloud-redis redis-cli ping 2>&1)"
dbs="$(podman exec nextcloud-redis redis-cli dbsize 2>&1)"
t_match "redis DBSIZE is a number (>= 0)" '^[0-9]+$' "$dbs"
t_match "PHP session handler is redis" 'session\.save_handler => redis' "$(podman exec nextcloud-app php -i 2>/dev/null | grep -m1 'session.save_handler')"
# Nextcloud really talks to redis: a request keeps the key space non-empty after logging in
t_ge "redis holds Nextcloud keys after the authenticated requests above" 1 "$(podman exec nextcloud-redis redis-cli dbsize 2>/dev/null | tr -dc 0-9)"

# ======================= Database ====================================================================
DBN="$(cfg DB_NAME)"
tables="$(podman exec nextcloud-db sh -c 'mariadb -N -u root -p"$MARIADB_ROOT_PASSWORD" -e "select count(*) from information_schema.tables where table_schema=\"'"$DBN"'\""' 2>&1 | redact)"
t_match "database query succeeded and returned a number" '^[0-9]+$' "$tables"
t_ge "database '$DBN' has more than 100 tables" 101 "$(tr -dc 0-9 <<<"$tables")"

# ======================= background jobs (slow) ===========================================================
echo "   --- background jobs (cron fires every 5 minutes) ---"
lastcron() { occ config:app:get core lastcron | tr -dc 0-9; }
changed() { [ "$(lastcron)" != "$BASE_CRON" ] && [ -n "$(lastcron)" ]; }
BASE_CRON="$(lastcron)"
t_match "lastcron is recorded (unix timestamp)" '^[0-9]{10}$' "$BASE_CRON"
if [ -n "${T_QUICK:-}" ] && [ "${T_QUICK}" != 0 ]; then
    t_skip "background jobs: lastcron advances within 330 s (proof that cron runs)" "T_QUICK=1"
else
    t_wait "background jobs: lastcron advances within 330 s (proof that cron runs)" 330 changed
fi
now="$(date +%s)"; lc="$(lastcron)"
age=$((now - ${lc:-0}))
if [ "${lc:-0}" -gt 0 ] && [ "$age" -le 360 ]; then t_pass "newest lastcron is not older than 6 minutes (age ${age}s)"
else t_fail "newest lastcron is not older than 6 minutes" "lastcron=$lc age=${age}s"; fi

t_end
