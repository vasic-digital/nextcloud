#!/usr/bin/env bash
# ===========================================================================
#  t05-smb — LIVE SMB test against the real Samba share.
#
#  Runs tests/smb-live-test.sh (add / modify / rename / remove of files and
#  directories as the Samba account, in both directions with Nextcloud, plus
#  on-disk ownership checks) and then proves the test can FAIL: it gives the
#  Nextcloud user's files directory to a sub-uid — exactly the state that used to
#  cause NT_STATUS_ACCESS_DENIED — and requires the SMB test to fail, then
#  restores the ownership.
#
#  Needs SMB_TEST_USER / SMB_TEST_PASSWORD (env or .env) and `smbclient`.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t05-smb "SMB add/modify/remove against the live share"

if ! command -v smbclient >/dev/null 2>&1; then t_skip "smbclient present" "smbclient not installed"; t_end; exit 0; fi
if [ -z "$(cfg SMB_TEST_USER)" ] || [ -z "$(cfg SMB_TEST_PASSWORD)" ]; then
    t_skip "SMB credentials configured" "SMB_TEST_USER / SMB_TEST_PASSWORD not set"; t_end; exit 0
fi

NC_USER="$(cfg NC_TEST_USER "$(nc_admin_user)")"
FILES_DIR="$(data_dir)/$NC_USER/files"
t_check "the Nextcloud user's files directory exists on the host" test -d "$FILES_DIR"

# --- 1. positive: the full SMB test --------------------------------------------
out="$("$T_ROOT/tests/smb-live-test.sh" 2>&1)"; rc=$?
summary="$(printf '%s\n' "$out" | tail -1)"
t_eq "smb-live-test.sh exits 0" "0" "$rc"
t_match "every SMB check passed (0 failed)" '^[0-9]+ passed, 0 failed$' "$summary"
n="${summary%% passed*}"
t_ge "the SMB suite ran at least 30 checks" 30 "${n:-0}"
printf '%s\n' "$out" | redact > "$TEST_EVIDENCE_DIR/logs/t05-smb-full-output.txt"

# --- 2. repeatability: the same suite again, same result -------------------------
out2="$("$T_ROOT/tests/smb-live-test.sh" 2>&1)"; rc2=$?
t_eq "second run exits 0" "0" "$rc2"
t_eq "second run reports the same totals" "$summary" "$(printf '%s\n' "$out2" | tail -1)"

# --- 3. nothing left behind ----------------------------------------------------
leftover="$(find "$FILES_DIR" -maxdepth 1 -name 'smb-live-test-*' | wc -l)"
t_eq "no smb-live-test-* leftovers in the files directory" "0" "$leftover"

# --- 4. negative control: the OLD bug must make the test fail ---------------------
restore_owner() { podman unshare sh -c 'chown "$(id -u):$(id -g)" "$1"' _ "$FILES_DIR"; }
trap 'restore_owner; _t_cleanup_tmp' EXIT
before="$(stat -c %u "$FILES_DIR")"
podman unshare chown 1:1 "$FILES_DIR"          # 1 inside the namespace = a sub-uid on the host
foreign="$(stat -c %u "$FILES_DIR")"
t_ne "negative control set up: directory now owned by a foreign (sub-)uid" "$before" "$foreign"
nout="$("$T_ROOT/tests/smb-live-test.sh" 2>&1)"; nrc=$?
t_ne "SMB test FAILS when the directory is owned by a sub-uid" "0" "$nrc"
t_match "failure is the original NT_STATUS_ACCESS_DENIED" 'NT_STATUS_ACCESS_DENIED' "$nout"
restore_owner
t_eq "ownership restored to the invoking user" "$before" "$(stat -c %u "$FILES_DIR")"
nout2="$("$T_ROOT/tests/smb-live-test.sh" 2>&1)"; nrc2=$?
t_eq "SMB test passes again after the restore" "0" "$nrc2"
trap _t_cleanup_tmp EXIT

t_end
