#!/usr/bin/env bash
# ===========================================================================
#  Shared test library. Every tests/tNN-*.sh module sources this file.
#
#  A module looks like:
#
#      #!/usr/bin/env bash
#      . "$(dirname "$0")/lib.sh"
#      t_begin "units" "systemd user units"          # id, title
#      t_check  "db unit is active"  systemctl --user is-active --quiet nextcloud-db.service
#      t_eq     "restart policy"     "always" "$(systemctl --user show -p Restart --value nextcloud-db)"
#      t_end                                         # prints summary, exit 1 if any FAIL
#
#  Evidence: every check appends one JSON line to $TEST_EVIDENCE_DIR/results.jsonl
#  (module, id, description, status, command, rc, duration_ms, redacted output)
#  and the full redacted output to $TEST_EVIDENCE_DIR/logs/<module>.log.
#  Secrets (every value of a *PASSWORD*/*SECRET* key in .env) are redacted from
#  everything that is stored or printed.
#
#  Rules for tests: deterministic (no sleeps without a condition: use
#  t_wait), self-cleaning, never print secrets, never hard-code ids, paths or
#  ports (read them from .env / the system).
# ===========================================================================
# shellcheck disable=SC2034

T_LIB_LOADED=1
T_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$T_ROOT" || exit 2

if [ -z "${TEST_EVIDENCE_DIR:-}" ]; then
    TEST_EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-tests.XXXXXX")"
    T_EPHEMERAL_EVIDENCE=1
fi
mkdir -p "$TEST_EVIDENCE_DIR/logs"
export TEST_EVIDENCE_DIR

T_MODULE=""; T_TITLE=""; T_PASS=0; T_FAIL=0; T_SKIP=0; T_SEQ=0
T_START_MS=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    T_G=$'\033[32m'; T_R=$'\033[31m'; T_Y=$'\033[33m'; T_D=$'\033[2m'; T_B=$'\033[1m'; T_0=$'\033[0m'
else
    T_G=""; T_R=""; T_Y=""; T_D=""; T_B=""; T_0=""
fi

# ---- configuration access (same precedence as setup.sh: environment, .env, .env.example)
cfg() {
    local key="$1" def="${2:-}" v="${!1:-}" f
    for f in "${NEXTCLOUD_ENV_FILE:-.env}" .env.example; do
        [ -n "$v" ] && break
        [ -r "$f" ] && v="$(sed -n "s/^${key}=//p" "$f" | tail -1)"
    done
    printf '%s' "${v:-$def}"
}

# ---- redaction -------------------------------------------------------------
_T_SECRETS=()
_t_load_secrets() {
    local f="${NEXTCLOUD_ENV_FILE:-.env}" line v
    [ -r "$f" ] || return 0
    while IFS= read -r line; do
        v="${line#*=}"
        [ "${#v}" -ge 6 ] && _T_SECRETS+=("$v")
    done < <(grep -E '^[A-Z_]*(PASSWORD|SECRET)[A-Z_]*=' "$f")
}
_t_load_secrets

# Filter: replace every known secret value with <redacted>.
redact() {
    local out; out="$(cat)"
    local s
    for s in "${_T_SECRETS[@]:-}"; do
        [ -n "$s" ] && out="${out//"$s"/<redacted>}"
    done
    printf '%s\n' "$out"
}

_now_ms() { date +%s%3N; }

# JSON-escape one string in pure bash (no subprocess: this runs once per check).
_jesc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    local LC_ALL=C
    s="${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}"
    printf '%s' "$s"
}

# _json key=value ... -> one JSON object on one line. Values of rc/ms/seq/pass/fail/skip
# that are plain integers are emitted as numbers, everything else as strings.
_json() {
    local out="{" first=1 kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [ "$first" = 1 ] || out+=","
        first=0
        case "$k" in
            rc|ms|seq|pass|fail|skip) if [[ "$v" =~ ^-?[0-9]+$ ]]; then out+="\"$k\":$v"; continue; fi ;;
        esac
        out+="\"$k\":\"$(_jesc "$v")\""
    done
    printf '%s}\n' "$out"
}

_record() {  # status description command rc ms output
    local status="$1" desc="$2" cmd="$3" rc="$4" ms="$5" out="$6"
    T_SEQ=$((T_SEQ + 1))
    local head
    head="$(printf '%s' "$out" | redact | head -c 1500)"
    _json "module=$T_MODULE" "seq=$T_SEQ" "status=$status" "description=$desc" \
          "command=$(printf '%s' "$cmd" | redact)" "rc=$rc" "ms=$ms" "output=$head" \
          "time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TEST_EVIDENCE_DIR/results.jsonl"
    {
        printf '[%s] %s #%s %s\n' "$(date -u +%T)" "$status" "$T_SEQ" "$desc"
        printf '    $ %s\n' "$(printf '%s' "$cmd" | redact)"
        printf '%s' "$out" | redact | sed 's/^/    | /' | head -60
    } >> "$TEST_EVIDENCE_DIR/logs/${T_MODULE}.log"
}

# ---- structure -------------------------------------------------------------
t_begin() {
    T_MODULE="$1"; T_TITLE="${2:-$1}"
    T_PASS=0; T_FAIL=0; T_SKIP=0
    T_START_MS="$(_now_ms)"
    printf '\n%s== %s: %s%s\n' "$T_B" "$T_MODULE" "$T_TITLE" "$T_0"
    : > "$TEST_EVIDENCE_DIR/logs/${T_MODULE}.log"
}

t_end() {
    local ms=$(( $(_now_ms) - T_START_MS ))
    printf '%s-- %s: %s%d passed%s, %s%d failed%s, %d skipped (%d ms)\n' \
        "$T_D" "$T_MODULE" "$T_G" "$T_PASS" "$T_0$T_D" "$([ "$T_FAIL" -gt 0 ] && echo "$T_R")" "$T_FAIL" "$T_0$T_D" "$T_SKIP" "$ms"
    printf '%s' "$T_0"
    _json "module=$T_MODULE" "title=$T_TITLE" "pass=$T_PASS" "fail=$T_FAIL" "skip=$T_SKIP" "ms=$ms" \
        >> "$TEST_EVIDENCE_DIR/modules.jsonl"
    [ -n "${T_EPHEMERAL_EVIDENCE:-}" ] && printf '   (evidence: %s)\n' "$TEST_EVIDENCE_DIR"
    [ "$T_FAIL" -eq 0 ]
}

t_info() { printf '   %s%s%s\n' "$T_D" "$*" "$T_0"; _record INFO "$*" "" 0 0 ""; }

t_pass() {  # t_pass "description" ["output"]
    T_PASS=$((T_PASS + 1)); printf '  %sPASS%s  %s\n' "$T_G" "$T_0" "$1"
    _record PASS "$1" "${3:-}" 0 0 "${2:-}"
}
t_fail() {  # t_fail "description" ["detail"]
    T_FAIL=$((T_FAIL + 1)); printf '  %sFAIL%s  %s\n' "$T_R" "$T_0" "$1"
    [ -n "${2:-}" ] && printf '        %s%s%s\n' "$T_D" "$(printf '%s' "$2" | redact | head -4)" "$T_0"
    _record FAIL "$1" "${3:-}" 1 0 "${2:-}"
}
t_skip() {  # t_skip "description" "reason"
    T_SKIP=$((T_SKIP + 1)); printf '  %sSKIP%s  %s (%s)\n' "$T_Y" "$T_0" "$1" "${2:-}"
    _record SKIP "$1" "" 0 0 "${2:-}"
}

# t_check "description" command args...   -> PASS when the command exits 0.
t_check() {
    local desc="$1"; shift
    local t0 out rc
    t0="$(_now_ms)"
    out="$("$@" 2>&1)"; rc=$?
    local ms=$(( $(_now_ms) - t0 ))
    if [ "$rc" -eq 0 ]; then
        T_PASS=$((T_PASS + 1)); printf '  %sPASS%s  %s\n' "$T_G" "$T_0" "$desc"
        _record PASS "$desc" "$*" "$rc" "$ms" "$out"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  %sFAIL%s  %s\n' "$T_R" "$T_0" "$desc"
        printf '        %s(rc=%s) %s%s\n' "$T_D" "$rc" "$(printf '%s' "$out" | redact | head -3 | tr '\n' ' ')" "$T_0"
        _record FAIL "$desc" "$*" "$rc" "$ms" "$out"
    fi
    return 0
}

# t_check_not "description" command args...  -> PASS when the command FAILS.
t_check_not() {
    local desc="$1"; shift
    local t0 out rc
    t0="$(_now_ms)"
    out="$("$@" 2>&1)"; rc=$?
    local ms=$(( $(_now_ms) - t0 ))
    if [ "$rc" -ne 0 ]; then
        T_PASS=$((T_PASS + 1)); printf '  %sPASS%s  %s\n' "$T_G" "$T_0" "$desc"
        _record PASS "$desc" "! $*" "$rc" "$ms" "$out"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  %sFAIL%s  %s\n' "$T_R" "$T_0" "$desc"
        printf '        %s(expected failure, got rc=0) %s%s\n' "$T_D" "$(printf '%s' "$out" | redact | head -2 | tr '\n' ' ')" "$T_0"
        _record FAIL "$desc" "! $*" "$rc" "$ms" "$out"
    fi
    return 0
}

t_eq() {  # t_eq "description" expected actual
    if [ "$2" = "$3" ]; then t_pass "$1" "expected=$2 actual=$3"
    else t_fail "$1" "expected: $2
actual:   $3"; fi
}
t_ne() {  # t_ne "description" unexpected actual
    if [ "$2" != "$3" ]; then t_pass "$1" "value=$3 (differs from $2)"
    else t_fail "$1" "value unexpectedly equals: $2"; fi
}
t_match() {  # t_match "description" 'ERE' "string"
    if [[ "$3" =~ $2 ]]; then t_pass "$1" "matched /$2/ in: ${3:0:200}"
    else t_fail "$1" "no match for /$2/ in: ${3:0:300}"; fi
}
t_nomatch() {
    if [[ ! "$3" =~ $2 ]]; then t_pass "$1" "no match for /$2/"
    else t_fail "$1" "unexpected match for /$2/ in: ${3:0:300}"; fi
}
t_ge() {  # t_ge "description" min actual
    if [ "$3" -ge "$2" ] 2>/dev/null; then t_pass "$1" "actual=$3 >= $2"
    else t_fail "$1" "expected >= $2, got: $3"; fi
}

# t_wait "description" TIMEOUT_SECONDS command args...  -> polls every second.
t_wait() {
    local desc="$1" timeout="$2"; shift 2
    local t0 i out="" rc=1
    t0="$(_now_ms)"
    for ((i = 0; i < timeout; i++)); do
        out="$("$@" 2>&1)" && { rc=0; break; }
        sleep 1
    done
    local ms=$(( $(_now_ms) - t0 ))
    if [ "$rc" -eq 0 ]; then
        T_PASS=$((T_PASS + 1)); printf '  %sPASS%s  %s %s(%d ms)%s\n' "$T_G" "$T_0" "$desc" "$T_D" "$ms" "$T_0"
        _record PASS "$desc" "wait ${timeout}s: $*" 0 "$ms" "$out"
    else
        T_FAIL=$((T_FAIL + 1)); printf '  %sFAIL%s  %s (timed out after %ss)\n' "$T_R" "$T_0" "$desc" "$timeout"
        _record FAIL "$desc" "wait ${timeout}s: $*" 1 "$ms" "$out"
    fi
    return 0
}

# ---- helpers ---------------------------------------------------------------
me_uid() { id -u; }
me_user() { id -un; }

# Run a snippet with setup.sh's functions loaded (sourced, so main() is not run).
# Extra environment can be passed as VAR=value before the call, e.g.
#   NEXTCLOUD_ENV_FILE=/tmp/x.env in_setup 'image_of nextcloud'
in_setup() {
    bash -c 'set -Eeuo pipefail; source ./setup.sh; '"$1"
}

# A throw-away directory removed at exit of the module.
_T_TMPS=()
t_tmpdir() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-test.XXXXXX")"
    _T_TMPS+=("$d"); printf '%s' "$d"
}
_t_cleanup_tmp() { local d; for d in "${_T_TMPS[@]:-}"; do [ -n "$d" ] && rm -rf -- "$d"; done; }
trap _t_cleanup_tmp EXIT

# Admin credentials and URLs of the live instance.
nc_admin_user() { cfg NEXTCLOUD_ADMIN_USER; }
nc_admin_pass() { cfg NEXTCLOUD_ADMIN_PASSWORD; }
nc_https_port() { cfg NEXTCLOUD_HTTPS_PORT; }
nc_http_port()  { cfg NEXTCLOUD_PORT; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1);exit}}'; }
data_dir() { cfg DATA_HOST_PATH; }

# curl against the live HTTPS endpoint with the generated certificate as the CA.
https_curl() { curl -sS --max-time 30 --cacert "$T_ROOT/tls/site.crt" "$@"; }
# WebDAV request as admin: dav METHOD PATH [curl args...]
dav() {
    local m="$1" p="$2"; shift 2
    https_curl -u "$(nc_admin_user):$(nc_admin_pass)" -X "$m" "$@" \
        "https://127.0.0.1:$(nc_https_port)/remote.php/dav/files/$(nc_admin_user)/${p#/}"
}

# ---- stack helpers (added for the disruptive modules; safe for everyone) ------
# Service names exactly as setup.sh defines them (never a second copy of the list).
t_services() { in_setup 'printf "%s\n" "${SERVICES[@]}"'; }
t_unit() { printf 'nextcloud-%s.service' "$1"; }
# True when all container units are active.
stack_all_active() {
    local s
    for s in $(t_services); do systemctl --user is-active --quiet "$(t_unit "$s")" || return 1; done
}
# True when HTTP and HTTPS both report an installed instance.
stack_web_ok() {
    curl -fsS --max-time 8 "http://127.0.0.1:$(nc_http_port)/status.php" 2>/dev/null | grep -q '"installed":true' || return 1
    https_curl -f --max-time 8 "https://127.0.0.1:$(nc_https_port)/status.php" 2>/dev/null | grep -q '"installed":true'
}
stack_healthy() { stack_all_active && stack_web_ok; }
# Container ids of the five containers (changes when a container is recreated).
stack_ctr_ids() {
    local s
    for s in $(t_services); do podman inspect -f '{{.Id}}' "nextcloud-$s" 2>/dev/null || echo missing; done | tr '\n' ' '
}
# Run ./setup.sh capturing combined output in $SETUP_OUT and the status in $SETUP_RC.
run_setup() {
    SETUP_OUT="$("$T_ROOT/setup.sh" "$@" 2>&1)"; SETUP_RC=$?
    printf '%s\n' "$SETUP_OUT" | redact > "$TEST_EVIDENCE_DIR/logs/${T_MODULE}-setup-${T_SEQ}.txt"
    return 0
}
# Same, feeding a confirmation word on stdin (restore/destroy).
run_setup_confirm() {
    local word="$1"; shift
    SETUP_OUT="$(printf '%s\n' "$word" | "$T_ROOT/setup.sh" "$@" 2>&1)"; SETUP_RC=$?
    printf '%s\n' "$SETUP_OUT" | redact > "$TEST_EVIDENCE_DIR/logs/${T_MODULE}-setup-${T_SEQ}.txt"
    return 0
}
sha256_of() { sha256sum | cut -d' ' -f1; }
occ() { "$T_ROOT/setup.sh" occ "$@" 2>&1; }
