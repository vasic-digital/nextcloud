#!/usr/bin/env bash
# ===========================================================================
#  LIVE SMB test: can the host account that Samba authenticates add, modify,
#  rename and remove files and directories in a Nextcloud user's folder — and
#  does Nextcloud see (and is it able to change) the same files?
#
#  Why it exists: Nextcloud used to run as a sub-UID (100032) under rootless
#  Podman, so everything it wrote was unwritable by the login user and SMB
#  writes failed with NT_STATUS_ACCESS_DENIED. The stack now runs as the
#  login user (UserNS=keep-id). This test proves it end to end, over the wire.
#
#  Usage:  tests/smb-live-test.sh [smb-host]        (default: the LAN IP)
#
#  Configuration (environment, or .env in the project root — never committed):
#    SMB_TEST_USER      account Samba authenticates          (required)
#    SMB_TEST_PASSWORD  its password                         (required)
#    SMB_TEST_SHARE     share that exports the data dir      (default Nextcloud)
#    SMB_TEST_HOST      SMB server                           (default LAN IP)
#    NC_TEST_USER       Nextcloud user whose files are used  (default: admin
#                       user from .env)
#
#  Leaves nothing behind: everything lives in one throw-away directory that is
#  removed at the end (and on failure/interrupt).
#  Exit status: 0 = every check passed, 1 = at least one failed.
# ===========================================================================
set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Read KEY from the environment, else from .env (without executing it).
cfg() {
    local key="$1" def="${2:-}" v="${!1:-}" f
    # environment, then .env, then the documented default in .env.example
    for f in .env .env.example; do
        [ -n "$v" ] && break
        [ -r "$f" ] && v="$(sed -n "s/^${key}=//p" "$f" | tail -1)"
    done
    printf '%s' "${v:-$def}"
}

SMB_USER="$(cfg SMB_TEST_USER)"
SMB_PASS="$(cfg SMB_TEST_PASSWORD)"
SHARE="$(cfg SMB_TEST_SHARE)"
NC_USER="$(cfg NC_TEST_USER "$(cfg NEXTCLOUD_ADMIN_USER)")"
NC_PASS="$(cfg NEXTCLOUD_ADMIN_PASSWORD)"
DATA="$(cfg DATA_HOST_PATH)"
HTTPS_PORT="$(cfg NEXTCLOUD_HTTPS_PORT)"
HOST="${1:-$(cfg SMB_TEST_HOST "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1);exit}}')")}"
HOST="${HOST:-127.0.0.1}"

[ -n "$HTTPS_PORT" ] && [ -n "$SHARE" ] && [ -n "$NC_USER" ] && [ -n "$DATA" ] || { echo "NEXTCLOUD_HTTPS_PORT, SMB_TEST_SHARE, the admin user and DATA_HOST_PATH must resolve (set them in .env)." >&2; exit 2; }
[ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ] || { echo "SMB_TEST_USER / SMB_TEST_PASSWORD are not set (env or .env)." >&2; exit 2; }
[ -n "$NC_PASS" ] || { echo "NEXTCLOUD_ADMIN_PASSWORD missing from .env." >&2; exit 2; }
command -v smbclient >/dev/null || { echo "smbclient is required." >&2; exit 2; }

TMP="$(mktemp -d)"
AUTH="$TMP/auth"
( umask 077; printf 'username = %s\npassword = %s\n' "$SMB_USER" "$SMB_PASS" > "$AUTH" )
RUN="smb-live-test-$(date +%Y%m%d-%H%M%S)-$$"
REL="$NC_USER/files/$RUN"                 # path inside the share
HOSTDIR="$DATA/$REL"                      # same place on the host disk
DAV="https://$HOST:$HTTPS_PORT/remote.php/dav/files/$NC_USER/$RUN"
CACERT="$ROOT/tls/site.crt"
[ -r "$CACERT" ] || CACERT=""

PASS=0; FAIL=0
cleanup() {
    smb "cd $NC_USER/files; deltree $RUN" >/dev/null 2>&1 || true
    [ -d "$HOSTDIR" ] && rm -rf "$HOSTDIR" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo; echo "interrupted"; exit 130' INT TERM

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_BAD=""; C_DIM=""; C_OFF=""; }

# Run one smbclient command line against the share; prints output, rc != 0 or
# any NT_STATUS_ error in the output counts as failure.
smb() { smbclient "//$HOST/$SHARE" -A "$AUTH" -c "$1" 2>&1; }
smb_ok() {
    local out
    out="$(smb "$1")"; local rc=$?
    SMB_OUT="$out"
    [ $rc -eq 0 ] && ! grep -q 'NT_STATUS_' <<<"$out"
}
dav() {   # dav METHOD URL-suffix [curl args...]
    local m="$1" p="$2"; shift 2
    local tls=(-k)
    [ -n "${CACERT:-}" ] && tls=(--cacert "$CACERT")
    curl -s "${tls[@]}" -u "$NC_USER:$NC_PASS" -X "$m" "$@" "$DAV$p"
}
davcode() { local m="$1" p="$2"; shift 2; dav "$m" "$p" -o /dev/null -w '%{http_code}' "$@"; }

check() {   # check "description" command...
    local name="$1"; shift
    if "$@"; then PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$C_OK" "$C_OFF" "$name"
    else          FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$C_BAD" "$C_OFF" "$name"
                  [ -n "${SMB_OUT:-}" ] && printf '        %s%s%s\n' "$C_DIM" "$(head -3 <<<"$SMB_OUT")" "$C_OFF"
    fi
    SMB_OUT=""
}
owned_by_me()    { [ "$(stat -c %U "$1" 2>/dev/null)" = "$(id -un)" ]; }
same_content()   { cmp -s "$1" "$2"; }

printf 'SMB live test  //%s/%s as %s  ->  Nextcloud user "%s"  (%s)\n' "$HOST" "$SHARE" "$SMB_USER" "$NC_USER" "$RUN"
printf 'host path: %s\n\n' "$HOSTDIR"

echo "== 1. connect and browse"
check "authenticate and list the share root"           smb_ok "ls"
check "list $NC_USER/files"                             smb_ok "cd $NC_USER/files; ls"

echo "== 2. SMB -> add directories and files"
printf 'version one %s\n' "$RUN" > "$TMP/v1.txt"
printf 'VERSION TWO, a longer replacement body for %s\n' "$RUN" > "$TMP/v2.txt"
head -c 1048576 /dev/urandom > "$TMP/big.bin"
check "mkdir test directory"                            smb_ok "cd $NC_USER/files; mkdir $RUN"
check "mkdir nested directories"                        smb_ok "cd $REL; mkdir sub; cd sub; mkdir deeper"
check "put a text file"                                 smb_ok "cd $REL; put $TMP/v1.txt note.txt"
check "put a 1 MiB binary file into a nested dir"       smb_ok "cd $REL/sub/deeper; put $TMP/big.bin big.bin"
check "read the text file back, byte-identical"         bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; smb_ok 'cd $REL; get note.txt $TMP/back1.txt' && cmp -s '$TMP/v1.txt' '$TMP/back1.txt'"
check "read the binary back, byte-identical"            bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; smb_ok 'cd $REL/sub/deeper; get big.bin $TMP/back2.bin' && cmp -s '$TMP/big.bin' '$TMP/back2.bin'"

echo "== 3. SMB -> modify and rename"
check "overwrite (modify) the text file"                smb_ok "cd $REL; put $TMP/v2.txt note.txt"
check "modified content is what was written"            bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; smb_ok 'cd $REL; get note.txt $TMP/back3.txt' && cmp -s '$TMP/v2.txt' '$TMP/back3.txt'"
check "rename a file"                                   smb_ok "cd $REL; rename note.txt renamed.txt"
check "rename a directory"                              smb_ok "cd $REL; rename sub subdir"
check "old names are gone, new names are listed"        bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; o=\$(smb 'cd $REL; ls'); grep -q renamed.txt <<<\"\$o\" && grep -q subdir <<<\"\$o\" && ! grep -qE ' note.txt| sub ' <<<\"\$o\""

echo "== 4. on disk: everything belongs to $(id -un)"
check "directory is owned by $(id -un)"                 owned_by_me "$HOSTDIR"
check "SMB-created file is owned by $(id -un)"          owned_by_me "$HOSTDIR/renamed.txt"
check "nested file is owned by $(id -un)"               owned_by_me "$HOSTDIR/subdir/deeper/big.bin"
check "no file in the test tree has another owner"      bash -c "[ -z \"\$(find '$HOSTDIR' -not -user '$(id -un)' -print -quit)\" ]"

echo "== 5. Nextcloud sees what SMB wrote (HTTPS WebDAV, as $NC_USER)"
check "PROPFIND lists the SMB-created file"             bash -c "$(declare -f dav); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; dav PROPFIND / -H 'Depth: 1' | grep -q renamed.txt"
check "GET returns the SMB-written content"             bash -c "$(declare -f dav); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; dav GET /renamed.txt | cmp -s - '$TMP/v2.txt'"
check "nested binary is served intact"                  bash -c "$(declare -f dav); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; dav GET /subdir/deeper/big.bin | cmp -s - '$TMP/big.bin'"

echo "== 6. Nextcloud -> add; SMB can read, modify, rename, delete it"
printf 'created by Nextcloud %s\n' "$RUN" > "$TMP/nc.txt"
check "WebDAV MKCOL creates a directory"                bash -c "$(declare -f dav davcode); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; [ \"\$(davcode MKCOL /from-nc)\" = 201 ]"
check "WebDAV PUT creates a file in it"                 bash -c "$(declare -f dav davcode); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; [ \"\$(davcode PUT /from-nc/nc.txt -T '$TMP/nc.txt')\" = 201 ]"
check "Nextcloud-created file is owned by $(id -un)"    owned_by_me "$HOSTDIR/from-nc/nc.txt"
check "Nextcloud-created dir is owned by $(id -un)"     owned_by_me "$HOSTDIR/from-nc"
check "SMB reads the Nextcloud-created file"            bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; smb_ok 'cd $REL/from-nc; get nc.txt $TMP/nc.back' && cmp -s '$TMP/nc.txt' '$TMP/nc.back'"
check "SMB modifies the Nextcloud-created file"         smb_ok "cd $REL/from-nc; put $TMP/v2.txt nc.txt"
check "SMB adds a file next to it"                      smb_ok "cd $REL/from-nc; put $TMP/v1.txt added-by-smb.txt"
check "SMB renames the Nextcloud-created file"          smb_ok "cd $REL/from-nc; rename nc.txt nc-renamed.txt"
check "Nextcloud serves the SMB-modified content"       bash -c "$(declare -f dav); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; dav GET /from-nc/nc-renamed.txt | cmp -s - '$TMP/v2.txt'"

echo "== 7. SMB -> remove"
check "delete the Nextcloud-created file"               smb_ok "cd $REL/from-nc; rm nc-renamed.txt"
check "delete the SMB-created text file"                smb_ok "cd $REL; rm renamed.txt"
check "delete a nested file"                            smb_ok "cd $REL/subdir/deeper; rm big.bin"
check "remove nested directories (deepest first)"       smb_ok "cd $REL/subdir; rmdir deeper; cd ..; rmdir subdir"
check "remove the Nextcloud-created directory"          bash -c "$(declare -f smb smb_ok); HOST=$HOST SHARE=$SHARE AUTH=$AUTH; smb_ok 'cd $REL/from-nc; rm added-by-smb.txt' && smb_ok 'cd $REL; rmdir from-nc'"
check "everything is gone on disk"                      bash -c "[ -z \"\$(ls -A '$HOSTDIR' 2>/dev/null)\" ]"
check "Nextcloud no longer lists the deleted entries"   bash -c "$(declare -f dav); NC_USER='$NC_USER' NC_PASS='$NC_PASS' DAV='$DAV' CACERT='$CACERT'; ! dav PROPFIND / -H 'Depth: 1' | grep -qE 'renamed.txt|subdir|from-nc'"
check "remove the test directory itself"                smb_ok "cd $NC_USER/files; rmdir $RUN"
check "test directory is gone on disk"                  bash -c "[ ! -e '$HOSTDIR' ]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
