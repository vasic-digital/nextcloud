#!/usr/bin/env bash
# ===========================================================================
#  t01-static: static analysis of the repository. Changes nothing on the
#  running stack; renders into throw-away directories only.
# ===========================================================================
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

t_begin t01 "static analysis: syntax, templates, hard-coding, secrets, modes"

HOOK=config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh
LIVE_UNITS="${NEXTCLOUD_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
REAL_ENV="${NEXTCLOUD_ENV_FILE:-.env}"
QUADLET_BIN_T=""
for _c in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do
    [ -x "$_c" ] && { QUADLET_BIN_T="$_c"; break; }
done

# ---------------------------------------------------------------------------
# 1. Syntax
# ---------------------------------------------------------------------------
t_check "bash -n setup.sh" bash -n setup.sh
for f in tests/*.sh; do
    t_check "bash -n $f" bash -n "$f"
done
t_check "sh -n (POSIX) on the container hook" sh -n "$HOOK"
# Negative control: the syntax checker must really reject broken input.
_bad="$(t_tmpdir)/bad.sh"; printf 'if then fi (\n' > "$_bad"
t_check_not "negative control: bash -n rejects a broken script" bash -n "$_bad"

if command -v shellcheck >/dev/null 2>&1; then
    t_check "shellcheck --severity=error setup.sh tests/*.sh" \
        shellcheck --severity=error -e SC1091 setup.sh tests/*.sh
    printf 'echo $(\n' > "$_bad"
    t_check_not "negative control: shellcheck flags a broken script" shellcheck --severity=error "$_bad"
else
    t_skip "shellcheck" "shellcheck is not installed"
fi

_mode_exec() { [ -x "$1" ]; }
t_check "hook is executable (the entrypoint skips non-executable hooks)" _mode_exec "$HOOK"
_hookmode="$(stat -c %a "$HOOK")"
t_match "hook mode has the owner exec bit and is not world-writable" '^[0-7]?[0-7]?[157][0-7][0-5]$|^[0-7]*[57][0-7][0145]$' "$_hookmode"
for d in pre-installation post-installation before-starting pre-upgrade post-upgrade; do
    t_check "hook directory config/nextcloud-hooks/$d exists" test -d "config/nextcloud-hooks/$d"
done

# ---------------------------------------------------------------------------
# 2. Templates
# ---------------------------------------------------------------------------
# Tokens setup.sh substitutes: the left-hand side of every `-e "s|@X@|...`.
SUBST_TOKENS="$(grep -oE 's\|@[A-Z_]+@\|' setup.sh | tr -d 's|' | sort -u)"
TPL_TOKENS="$(grep -ohE '@[A-Z_]+@' systemd/*.in | sort -u)"
t_ge "setup.sh substitutes at least 10 tokens (extraction sanity)" 10 "$(printf '%s\n' "$SUBST_TOKENS" | grep -c .)"
t_ge "templates use at least 10 tokens (extraction sanity)" 10 "$(printf '%s\n' "$TPL_TOKENS" | grep -c .)"
_unknown="$(comm -23 <(printf '%s\n' "$TPL_TOKENS") <(printf '%s\n' "$SUBST_TOKENS") | tr '\n' ' ')"
t_eq "every @TOKEN@ in systemd/*.in is substituted by render_units" "" "$_unknown"
for f in systemd/*.in; do
    _u="$(comm -23 <(grep -ohE '@[A-Z_]+@' "$f" | sort -u) <(printf '%s\n' "$SUBST_TOKENS") | tr '\n' ' ')"
    t_eq "no unknown token in $f" "" "$_u"
done
_unused="$(comm -13 <(printf '%s\n' "$TPL_TOKENS") <(printf '%s\n' "$SUBST_TOKENS") | tr '\n' ' ')"
t_eq "every token render_units substitutes is used by some template (no dead substitutions)" "" "$_unused"

T=$(t_tmpdir)
mkdir -p "$T/units" "$T/run"
# Render with the real configuration; TRUSTED_PROXIES is set so that nothing
# needs the live network (render_units does not read it, write_env_files does).
cp "$REAL_ENV" "$T/env"
chmod 0600 "$T/env"
printf '\nTRUSTED_PROXIES=203.0.113.0/24\n' >> "$T/env"

_render() {  # _render ENVFILE RUNDIR UNITDIR
    NEXTCLOUD_ENV_FILE="$1" NEXTCLOUD_RUN_DIR="$2" NEXTCLOUD_QUADLET_DIR="$3" NEXTCLOUD_NO_RELOAD=1 \
        in_setup 'require_systemd; render_units'
}
t_check "render_units renders every template into a throw-away dir" _render "$T/env" "$T/run" "$T/units"

_nt=$(ls systemd/*.in | wc -l)
t_eq "rendered file count equals template count" "$_nt" "$(ls "$T/units" | wc -l)"
_left="$(grep -nE '@[A-Za-z_]+@' "$T"/units/* 2>/dev/null | head -5)"
t_eq "no @...@ placeholder left in any rendered unit" "" "$_left"
for f in systemd/*.in; do
    t_check "rendered counterpart exists: $(basename "${f%.in}")" test -s "$T/units/$(basename "${f%.in}")"
done

_dry() {  # _dry DIR -> prints generated unit names, fails on generator error
    local out rc
    out="$(QUADLET_UNIT_DIRS="$1" "$QUADLET_BIN_T" -dryrun -user 2>&1)"; rc=$?
    printf '%s\n' "$out" | grep -E '^---.*---$'
    return $rc
}
if [ -n "$QUADLET_BIN_T" ]; then
    t_check "quadlet -dryrun -user succeeds on the rendered dir" _dry "$T/units"
    _gen="$(_dry "$T/units" 2>/dev/null | sed 's/^---//; s/---$//' | sort | tr '\n' ' ')"
    for s in db redis app cron caddy; do
        t_match "quadlet generates nextcloud-$s.service" "nextcloud-$s\\.service" "$_gen"
    done
    t_match "quadlet generates nextcloud-network.service" 'nextcloud-network\.service' "$_gen"
    # Negative control: a template with a bogus key must make the generator fail.
    mkdir -p "$T/badunits"
    printf '[Container]\nImage=x\nBogusKeyThatDoesNotExist=1\n' > "$T/badunits/nextcloud-bad.container"
    t_check_not "negative control: quadlet rejects an invalid unit" _dry "$T/badunits"
else
    t_skip "quadlet -dryrun" "quadlet generator not found"
fi

# Live units must be exactly what setup.sh would render now. Only the (temp)
# RUN_DIR path is mapped back to the real one, because it is the one value that
# necessarily differs between a throw-away render and the live files.
sed -i "s|$T/run|$T_ROOT/.run|g" "$T"/units/*
if [ "$LIVE_UNITS" != "$T/units" ] && [ -d "$LIVE_UNITS" ]; then
    for f in "$T"/units/*; do
        b="$(basename "$f")"
        t_check "live unit $b matches what setup.sh renders now (not stale)" diff -u "$LIVE_UNITS/$b" "$f"
    done
    _liveextra="$(ls "$LIVE_UNITS" | grep -E '^nextcloud' | while read -r b; do [ -e "$T/units/$b" ] || echo "$b"; done | tr '\n' ' ')"
    t_eq "no stray nextcloud* unit in $LIVE_UNITS without a template" "" "$_liveextra"
    # Negative control for the diff approach.
    cp "$T/units/nextcloud-db.container" "$T/mut"; echo '# drift' >> "$T/mut"
    t_check_not "negative control: diff detects a drifted unit" diff -q "$LIVE_UNITS/nextcloud-db.container" "$T/mut"
else
    t_skip "live unit comparison" "no live unit dir $LIVE_UNITS"
fi

# ---------------------------------------------------------------------------
# 3. Hard-coding audit
# ---------------------------------------------------------------------------
# Scans code (comments stripped) for literals that must come from the system or
# from .env. Every exception is listed in the ALLOWLIST below with its reason.
mapfile -t AUDIT_FILES < <(ls setup.sh systemd/*.in Caddyfile docker/caddy/Containerfile tests/*.sh 2>/dev/null
                           find config -type f -name '*.sh' 2>/dev/null)
HOSTNAME_NOW="$(hostname 2>/dev/null || true)"
cat > "$T/audit.py" <<'PYEOF'
import os, re, sys

host = os.environ.get("AUDIT_HOST", "")
skip_base = {"lib.sh", "t01-static.sh"}   # the library and this audit's own pattern table

# name -> regex applied to the comment-stripped line
PATTERNS = {
    "numeric-id": re.compile(r"(?<![0-9.\w$])(33|999|1000|100000|100032)(?![0-9.\w])"),
    "user-name":  re.compile(r"milosvasic"),
    "mount-path": re.compile(r"/run/media"),
    "subnet-10.89": re.compile(r"10\.89\."),
    "lan-192.168": re.compile(r"192\.168\."),
    "home-path":  re.compile(r"/home/"),
    "port-literal": re.compile(r"(?<![0-9.\w])(8080|8280|52443)(?![0-9.\w])"),
}
if host:
    PATTERNS["host-name"] = re.compile(r"(?<![\w-])" + re.escape(host) + r"(?![\w-])")

# (file regex, pattern name, line regex, justification)
ALLOW = [
    (r"^setup\.sh$", "port-literal", r"^readonly DEFAULT_(HTTP|HTTPS)_PORT=",
     "the single definition of the default ports (overridable in .env)"),
    (r".*", "numeric-id", r"\\033\[\d+m",
     "ANSI colour escape codes, not ids"),
    (r"^setup\.sh$", "numeric-id", r"(sed_esc|STARTUP_TIMEOUT|chmod|umask)",
     "unreachable placeholder; kept explicit so a new hit is reviewed"),
    (r"^tests/", "numeric-id", r"(sleep|timeout|-ge|-le|-gt|-lt|--max-time|head -c|head -n|t_wait|t_ge|ms\b)",
     "durations, sizes and counts in tests, not ids"),
    (r"^systemd/nextcloud-(app|cron|db|redis)\.container\.in$", "numeric-id", r"Timeout(Start|Stop)Sec=\d+",
     "systemd timeouts in seconds"),
    (r"^systemd/nextcloud-db\.container\.in$", "numeric-id", r"Health(Interval|Timeout|StartPeriod)=",
     "health-check durations"),
    (r"^systemd/", "numeric-id", r"(Health|RestartSec|Retries)",
     "durations and retry counts"),
    (r"^tests/t11-docs\.sh$", "port-literal", r"dead references",
     "a label naming the retired port 8280 as a stale-doc pattern, not a configuration value"),
    (r"^tests/", "port-literal", r"(DEFAULT|default|fixture|FIXTURE|ignore)",
     "tests that assert on the documented defaults"),
]

def strip_comment(line):
    s = line.lstrip()
    if s.startswith("#"):
        return ""
    # trailing comment: whitespace + '#' + whitespace, outside the common quoted cases
    return re.sub(r"\s+#\s.*$", "", line)

findings = []
allowed = []
for path in sys.argv[1:]:
    if os.path.basename(path) in skip_base:
        continue
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for n, raw in enumerate(fh, 1):
            line = strip_comment(raw.rstrip("\n"))
            if not line.strip():
                continue
            for name, rx in PATTERNS.items():
                if not rx.search(line):
                    continue
                why = None
                for frx, pname, lrx, just in ALLOW:
                    if pname == name and re.search(frx, path) and re.search(lrx, line):
                        why = just
                        break
                if why:
                    allowed.append((path, n, name, why))
                else:
                    findings.append((path, n, name, line.strip()[:140]))
for p, n, name, text in findings:
    print(f"FINDING {p}:{n}: [{name}] {text}")
print(f"SUMMARY findings={len(findings)} allowed={len(allowed)} files={len(sys.argv)-1}")
sys.exit(1 if findings else 0)
PYEOF
_audit() { AUDIT_HOST="$HOSTNAME_NOW" python3 "$T/audit.py" "$@"; }
t_check "hard-coding audit: no forbidden literal (ids, user, paths, subnets, hostname, ports) outside the allowlist" \
    _audit "${AUDIT_FILES[@]}"
t_ge "audit scanned the expected set (setup.sh, 6 templates, Caddyfile, Containerfile, hook, tests)" 10 "${#AUDIT_FILES[@]}"
# Negative controls: the audit must flag each class of literal in a scratch file.
mkdir -p "$T/neg"
printf 'UserNS=keep-id:uid=1000,gid=1000\nowner=milosvasic\nd=/run/media/x\nn=10.89.0.0/24\nl=192.168.1.5\nh=/home/u\nP=8080\nx=%s\n' "${HOSTNAME_NOW:-hostx}" > "$T/neg/sample.in"
_negout="$(_audit "$T/neg/sample.in" || true)"
for k in numeric-id user-name mount-path subnet-10.89 lan-192.168 home-path port-literal; do
    t_match "negative control: audit detects [$k]" "\\[$k\\]" "$_negout"
done
[ -n "$HOSTNAME_NOW" ] && t_match "negative control: audit detects the host name" '\[host-name\]' "$_negout"
printf '# uid 1000 in a comment milosvasic\nx=1 # trailing 1000 comment\n' > "$T/neg/commented.in"
t_check "negative control: comments are not scanned" _audit "$T/neg/commented.in"

# ---------------------------------------------------------------------------
# 4. .env.example coverage / orphans
# ---------------------------------------------------------------------------
_keys_read() {
    {
        grep -ohE 'env_(or|get|need) +"?[A-Z][A-Z0-9_]+' setup.sh | awk '{gsub(/"/,"",$2); print $2}'
        # service_ids reads "${prefix}_RUN_USER|_UID|_GID" for APP, DB, REDIS
        if grep -qE 'env_(or|get) "\$\{prefix\}_(RUN_USER|UID|GID)"' setup.sh; then
            for p in APP DB REDIS; do printf '%s_%s\n' "$p" RUN_USER "$p" UID "$p" GID; done
        fi
        grep -ohE '\$\{[A-Z][A-Z0-9_]+:-' "$HOOK" | tr -d '${:-'
        grep -ohE '\bcfg +[A-Z][A-Z0-9_]+' tests/*.sh | awk '{print $2}'
    } | sort -u
}
_keys_example() { grep -E '^[A-Z][A-Z0-9_]*=' .env.example | cut -d= -f1 | sort -u; }
KEYS_READ="$(_keys_read)"
KEYS_EX="$(_keys_example)"
t_ge "extracted at least 20 config keys read by the code (sanity)" 20 "$(printf '%s\n' "$KEYS_READ" | grep -c .)"
t_ge "extracted at least 20 keys from .env.example (sanity)" 20 "$(printf '%s\n' "$KEYS_EX" | grep -c .)"
_missing="$(comm -23 <(printf '%s\n' "$KEYS_READ") <(printf '%s\n' "$KEYS_EX") | tr '\n' ' ')"
t_eq ".env.example documents every key setup.sh / the hook / tests read" "" "$_missing"
_orphans="$(comm -13 <(printf '%s\n' "$KEYS_READ") <(printf '%s\n' "$KEYS_EX") | tr '\n' ' ')"
t_eq ".env.example has no orphan key (every KEY= is read somewhere)" "" "$_orphans"
for k in NEXTCLOUD_MAINTENANCE_WINDOW_START NEXTCLOUD_OVERWRITE_CLI_URL DEFAULT_PHONE_REGION \
         APP_UID APP_GID APP_RUN_USER DB_UID DB_GID DB_RUN_USER REDIS_UID REDIS_GID REDIS_RUN_USER \
         NEXTCLOUD_IMAGE DB_IMAGE REDIS_IMAGE CADDY_IMAGE HELPER_IMAGE; do
    t_match "key $k is documented in .env.example" "(^|"$'\n'")${k}=" "$(grep -E '^[A-Z][A-Z0-9_]*=' .env.example)"
done
# Negative control for the set comparison.
_nc="$(comm -23 <(printf 'A\nNOT_IN_EXAMPLE\n') <(printf 'A\n') | tr '\n' ' ')"
t_eq "negative control: key comparison reports a missing key" "NOT_IN_EXAMPLE " "$_nc"

# ---------------------------------------------------------------------------
# 5. git hygiene
# ---------------------------------------------------------------------------
for p in .env .env.local .env.pre-restore.20260101-000000 .run/app.env .run/db.env tls/site.key tls/site.crt backups/x/db.sql data/file; do
    t_check "git check-ignore proves '$p' is ignored" git check-ignore -q "$p"
done
t_check_not "negative control: git check-ignore does not ignore README.md" git check-ignore -q README.md
t_check_not "negative control: git check-ignore does not ignore .env.example" git check-ignore -q .env.example
_tracked_bad="$(git ls-files | grep -E '^(\.env$|\.env\.local$|\.env\.pre-restore|\.run/|tls/|backups/|data/)' | tr '\n' ' ')"
t_eq "git ls-files contains no .env, .run/, tls/, backups/, data/ path" "" "$_tracked_bad"
_untracked_bad="$(git ls-files -o --exclude-standard | grep -E '^(\.env$|\.env\.local$|\.env\.pre-restore|\.run/|tls/|backups/|data/)' | tr '\n' ' ')"
t_eq "nothing sensitive is untracked-but-addable" "" "$_untracked_bad"

# ---------------------------------------------------------------------------
# 6. Secret scan of the working tree (tracked + addable files). Never prints a value.
# ---------------------------------------------------------------------------
SEC="$T/secrets.txt"; : > "$SEC"; chmod 0600 "$SEC"
if [ -r "$REAL_ENV" ]; then
    grep -E '^[A-Z_]*(PASSWORD|SECRET)[A-Z_]*=' "$REAL_ENV" | cut -d= -f2- | awk 'length($0) >= 6' | sort -u > "$SEC"
fi
_nsec="$(grep -c . "$SEC" || true)"
t_ge "collected live secret values to scan for (count only)" 1 "$_nsec"
{ git ls-files; git ls-files -o --exclude-standard; } | sort -u | while read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done > "$T/scanfiles"
t_ge "secret scan covers tracked + addable files" 10 "$(grep -c . "$T/scanfiles")"
_leak_scan() {  # prints the NAMES of files that contain any secret value
    local f
    while read -r f; do printf '%s\0' "$f"; done < "$1" | xargs -0 grep -lFf "$SEC" -- 2>/dev/null
}
_leaks="$(_leak_scan "$T/scanfiles" | tr '\n' ' ')"
t_eq "no live secret value appears in any tracked or addable working-tree file" "" "$_leaks"
# Negative control: a synthetic secret in a scratch file must be found by the same machinery.
printf 'zz-synthetic-secret-1234567\n' > "$T/fake_secret"; printf '%s\n' "$T/neg/leaky.txt" > "$T/fake_list"
printf 'prefix zz-synthetic-secret-1234567 suffix\n' > "$T/neg/leaky.txt"
_real_sec="$SEC"; SEC="$T/fake_secret"
t_match "negative control: the scanner finds a planted secret" 'leaky\.txt' "$(_leak_scan "$T/fake_list")"
SEC="$_real_sec"

# ---------------------------------------------------------------------------
# 7. File modes
# ---------------------------------------------------------------------------
_mode() { stat -c %a "$1" 2>/dev/null; }
t_eq ".env is mode 600" 600 "$(_mode "$REAL_ENV")"
if [ -d .run ]; then
    t_eq ".run directory is mode 700" 700 "$(_mode .run)"
    _any=0
    for f in .run/*.env; do
        [ -e "$f" ] || continue
        _any=1
        t_eq "$f is mode 600" 600 "$(_mode "$f")"
    done
    t_eq "at least one generated .run/*.env exists" 1 "$_any"
else
    t_skip ".run permissions" "no .run directory (stack never installed)"
fi
if [ -e tls/site.key ]; then
    t_eq "tls/site.key is mode 600" 600 "$(_mode tls/site.key)"
else
    t_skip "tls/site.key mode" "no key yet"
fi

# ---------------------------------------------------------------------------
# 8. No compose remnants
# ---------------------------------------------------------------------------
_compose="$(ls compose.y*ml docker-compose.y*ml podman-compose.y*ml 2>/dev/null | tr '\n' ' ')"
t_eq "no compose file in the tree" "" "$_compose"
_code="$(awk '/^[[:space:]]*#/ {next} {sub(/[[:space:]]+#[[:space:]].*$/, ""); print FNR": "$0}' setup.sh \
         | grep -E 'podman-compose|docker-compose|compose up|compose down|podman compose' | head -5)"
t_eq "setup.sh has no podman-compose / compose up invocation (comments excluded)" "" "$_code"
# Negative control: the awk filter must catch a real invocation.
printf 'podman-compose up -d\n# podman-compose in a comment\n' > "$T/neg/compose.sh"
_nc2="$(awk '/^[[:space:]]*#/ {next} {print}' "$T/neg/compose.sh" | grep -cE 'podman-compose')"
t_eq "negative control: filter catches an uncommented podman-compose call" 1 "$_nc2"

t_end
