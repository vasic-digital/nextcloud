#!/usr/bin/env bash
# ===========================================================================
#  Run the whole LIVE test suite and produce machine-generated evidence.
#
#  Usage:  tests/run-all.sh [options]
#
#    --quick             skip the slow cron wait (T_QUICK=1) and the destructive modules
#    --non-destructive   skip t07-resilience and t08-backup-restore (they restart
#                        services, stop the database, destroy and restore the instance)
#    --only a,b,c        run only these modules (ids or file names, e.g. t03,t04)
#    --skip a,b          run everything except these
#    --evidence-dir DIR  where to write the evidence (default tests/evidence/<UTC time>)
#    --list              list the modules and exit
#    -h, --help
#
#  Evidence directory contents:
#    report.md            human-readable verdict, per-module table, every check
#    results.json         the same, machine-readable (totals, modules, failures, checks)
#    results.jsonl        one record per check: command, rc, duration, redacted output
#    modules.jsonl        per-module summaries
#    module-exit.tsv      module / exit code / seconds
#    environment.txt      host, tool versions, git commit, image digests, unit states,
#                         SHA-256 of the code under test
#    logs/  console/      full per-module logs and raw console output (redacted)
#    MANIFEST.sha256      SHA-256 of every file above (sha256sum -c MANIFEST.sha256)
#
#  Exit status: 0 = every module passed, 1 = at least one check/module failed,
#  2 = the suite could not start (stack not running, missing tools).
# ===========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT" || exit 2

# Order matters: read-only first, then functional, then destructive, then docs.
MODULES=(t01-static t09-dynamic t02-units t03-ownership t10-security t04-https t06-nextcloud t05-smb t07-resilience t08-backup-restore t11-docs)
DESTRUCTIVE=(t07-resilience t08-backup-restore)

quick=0; nondestructive=0; only=""; skip=""; EV=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quick)           quick=1; nondestructive=1 ;;
        --non-destructive) nondestructive=1 ;;
        --only)            only="$2"; shift ;;
        --skip)            skip="$2"; shift ;;
        --evidence-dir)    EV="$2"; shift ;;
        --list)            printf '%s\n' "${MODULES[@]}"; exit 0 ;;
        -h|--help)         awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)                 echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

in_list() { local x="$1" list=",$2,"; [[ "$list" == *",$x,"* ]]; }
selected() {   # selected MODULE
    local m="$1" short="${1%%-*}"
    if [ -n "$only" ] && ! in_list "$m" "$only" && ! in_list "$short" "$only"; then return 1; fi
    if [ -n "$skip" ] && { in_list "$m" "$skip" || in_list "$short" "$skip"; }; then return 1; fi
    if [ "$nondestructive" = 1 ]; then
        local d; for d in "${DESTRUCTIVE[@]}"; do [ "$m" = "$d" ] && return 1; done
    fi
    return 0
}

[ -n "$EV" ] || EV="$ROOT/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EV/logs" "$EV/console"
export TEST_EVIDENCE_DIR="$EV"
[ "$quick" = 1 ] && export T_QUICK=1

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"      # for redact()

# ---- preflight --------------------------------------------------------------
for t in python3 curl podman systemctl sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 2; }
done
if ! systemctl --user is-active --quiet nextcloud-app.service; then
    echo "the stack is not running; start it with ./setup.sh up" >&2; exit 2
fi

# ---- environment snapshot -----------------------------------------------------
{
    echo "started:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host:         $(hostname)   kernel $(uname -r)"
    echo "user:         $(id -un) (uid $(id -u), gid $(id -g))"
    echo "ns uid map:   $(podman unshare cat /proc/self/uid_map | tr -s ' ' | tr '\n' ';')"
    echo "podman:       $(podman --version)"
    echo "systemd:      $(systemctl --version | head -1)"
    echo "quadlet:      $(ls /usr/libexec/podman/quadlet /usr/lib/podman/quadlet 2>/dev/null | head -1)"
    echo "git commit:   $(git rev-parse --short HEAD 2>/dev/null) on $(git rev-parse --abbrev-ref HEAD 2>/dev/null)  (working tree: $(git status --porcelain 2>/dev/null | wc -l) uncommitted paths)"
    echo "options:      quick=$quick non-destructive=$nondestructive only='${only}' skip='${skip}'"
    echo
    echo "--- unit states"
    for u in network db redis app cron caddy; do
        n="nextcloud-$u.service"; [ "$u" = network ] && n="nextcloud-network.service"
        printf '%-28s %s (%s)\n' "$n" "$(systemctl --user is-active "$n" 2>&1)" "$(systemctl --user show -p SubState --value "$n")"
    done
    echo
    echo "--- containers and images"
    podman ps --format '{{.Names}}  {{.Image}}  {{.Status}}' --filter name='^nextcloud-' | sort
    echo
    echo "--- image digests"
    for c in db redis app cron caddy; do
        podman inspect --format '{{.ImageName}}  {{.Image}}' "nextcloud-$c" 2>/dev/null
    done | sort -u
    echo
    echo "--- sha256 of the code under test"
    ( cd "$ROOT" && sha256sum setup.sh Caddyfile docker/caddy/Containerfile systemd/*.in config/nextcloud-hooks/before-starting/*.sh tests/*.sh tests/report.py .env.example 2>/dev/null )
} 2>&1 | redact > "$EV/environment.txt"

# ---- run the modules ------------------------------------------------------------
: > "$EV/module-exit.tsv"
overall=0
printf '\nEvidence directory: %s\n' "$EV"
for m in "${MODULES[@]}"; do
    f="$ROOT/tests/$m.sh"
    selected "$m" || { printf '\n-- %s: not selected\n' "$m"; continue; }
    if [ ! -x "$f" ]; then
        printf '\n-- %s: MISSING or not executable (%s)\n' "$m" "$f"
        printf '%s\t%s\t%s\n' "$m" 127 0 >> "$EV/module-exit.tsv"; overall=1; continue
    fi
    t0=$(date +%s)
    "$f" 2>&1 | redact | tee "$EV/console/$m.txt"
    rc=${PIPESTATUS[0]}
    t1=$(date +%s)
    printf '%s\t%s\t%s\n' "$m" "$rc" "$((t1 - t0))" >> "$EV/module-exit.tsv"
    [ "$rc" -eq 0 ] || overall=1
done
echo "finished:     $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$EV/environment.txt"

# ---- report + manifest ----------------------------------------------------------------
python3 "$ROOT/tests/report.py" "$EV" || overall=1
( cd "$EV" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
ln -sfn "$EV" "$ROOT/tests/evidence/latest" 2>/dev/null || true

printf '\n%s\n' "================================================================"
sed -n '1,/^| Module/p' "$EV/report.md" | head -3
printf '%s\n' "Report:    $EV/report.md"
printf '%s\n' "Manifest:  $EV/MANIFEST.sha256   (verify: cd '$EV' && sha256sum -c MANIFEST.sha256)"
exit "$overall"
