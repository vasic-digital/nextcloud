#!/usr/bin/env bash
# ===========================================================================
#  t11-docs: the documentation must match the code. Read-only, no containers.
#
#  Every check collects "file:line: problem" findings; the check FAILS when any
#  exist, so stale or missing documentation is a legitimate failure.
# ===========================================================================
. "$(dirname "$0")/lib.sh"
t_begin t11-docs 'documentation matches the code'

DOCS=(README.md AGENTS.md)
[ -r tests/README.md ] && DOCS+=(tests/README.md)
HELP_TXT="$(t_tmpdir)/help.txt"
./setup.sh help >"$HELP_TXT" 2>&1

# ---- helpers ---------------------------------------------------------------
# findings_check "description" <command printing findings, one per line>
findings_check() {
    local desc="$1"; shift
    local out
    out="$("$@" 2>&1)"
    if [ -z "$out" ]; then
        t_pass "$desc"
    else
        t_fail "$desc" "$out"
        # t_fail shows only 4 lines; print the rest so nothing is hidden.
        if [ "$(printf '%s\n' "$out" | wc -l)" -gt 4 ]; then
            printf '%s\n' "$out" | sed -n '5,40p' | sed 's/^/        /'
        fi
    fi
}

# Parse the dispatch case in main(): prints "primary alias1 alias2" per line.
dispatch_labels() {
    awk '
        /^main\(\)/ {inmain=1}
        inmain && /case "\$command" in/ {incase=1; next}
        incase && /^[[:space:]]*esac/ {exit}
        incase && match($0, /^[[:space:]]+[^ )]+\)/) {
            lab=substr($0, RSTART, RLENGTH); gsub(/[[:space:]]|\)/, "", lab)
            if (lab == "*") next
            gsub(/\|/, " ", lab); print lab
        }' setup.sh
}
# The case label line number of a command (for file:line).
dispatch_line() { grep -nE "^[[:space:]]+(${1}|[^ )]*\|${1})[|)]" setup.sh | head -1 | cut -d: -f1; }

# Section of a markdown file: md_section FILE 'heading regex' -> prints "lineno:text"
md_section() {
    awk -v pat="$2" '
        /^```/ {fence = !fence}
        !fence && /^## / { if (on) exit; if ($0 ~ pat) on=1 }
        on {print NR ":" $0}' "$1"
}

py() { python3 -I - "$@"; }

mapfile -t LABELS < <(dispatch_labels)
PRIMARIES=(); ALIASES=()
for l in "${LABELS[@]}"; do
    read -ra w <<<"$l"
    case "${w[0]}" in help) ;; esac
    PRIMARIES+=("${w[0]}")
    for a in "${w[@]:1}"; do ALIASES+=("${w[0]}=$a"); done
done
t_ge "dispatch case parsed from setup.sh (commands found)" 10 "${#PRIMARIES[@]}"

# ===========================================================================
# 1. Commands: dispatch <-> help header <-> README reference table
# ===========================================================================
chk_cmds_help() {
    local c
    for c in "${PRIMARIES[@]}"; do
        grep -qE "^   ${c}( |$)" "$HELP_TXT" ||
            echo "setup.sh:$(dispatch_line "$c"): command '$c' is in the dispatch but not in the './setup.sh help' usage header"
    done
    # phantom: commands listed in the header must exist in the dispatch
    local h
    while read -r h; do
        printf '%s\n' "${PRIMARIES[@]}" | grep -qx "$h" ||
            echo "setup.sh:header: '$h' is listed in the usage header but is not a dispatch command"
    done < <(sed -nE 's/^   ([a-z][a-z-]*)( .*|)$/\1/p' "$HELP_TXT" | sort -u)
}
findings_check "every dispatch command is in the setup.sh help header, and the header lists no phantom command" chk_cmds_help

readme_cmds() {  # first backticked word in each row of the setup.sh reference table
    md_section README.md '^## `setup.sh` reference' | sed -nE 's/^([0-9]+):\| `([a-z][a-z-]*)[ `].*/\1 \2/p'
}
chk_cmds_readme() {
    local c ln rows
    rows="$(readme_cmds)"
    for c in "${PRIMARIES[@]}"; do
        printf '%s\n' "$rows" | awk '{print $2}' | grep -qx "$c" ||
            echo "README.md: command '$c' (setup.sh:$(dispatch_line "$c")) is missing from the 'setup.sh reference' table"
    done
    while read -r ln c; do
        printf '%s\n' "${PRIMARIES[@]}" | grep -qx "$c" ||
            echo "README.md:$ln: table documents phantom command '$c'"
    done <<<"$rows"
    local p a
    for p in "${ALIASES[@]}"; do
        a="${p#*=}"
        case "$a" in -*) continue ;; esac   # -h/--help are flags, not documented aliases
        md_section README.md '^## `setup.sh` reference' | grep -E '^[0-9]+:Aliases' | grep -q "\`$a\` = \`${p%%=*}\`" ||
            echo "README.md: alias '$a' = '${p%%=*}' is not documented in the 'Aliases:' line"
    done
}
findings_check "README setup.sh reference table documents every command and alias, and no phantom one" chk_cmds_readme

# ===========================================================================
# 2. Configuration keys
# ===========================================================================
code_keys() {  # prints "KEY<TAB>where"
    grep -noE '(env_or|env_get|env_need)[[:space:]]+"?[A-Z][A-Z0-9_]+' setup.sh |
        awk -F'[: "]+' '{print $NF "\tsetup.sh:" $1}'
    # per-service account keys built from "${prefix}_..." in service_ids
    if grep -q '\${prefix}_UID' setup.sh; then
        local p s
        for p in APP DB REDIS; do for s in RUN_USER UID GID; do printf '%s_%s\tsetup.sh:service_ids\n' "$p" "$s"; done; done
    fi
    # hook environment
    grep -noE '\$\{?(NEXTCLOUD_[A-Z_]+|DEFAULT_[A-Z_]+)' config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh |
        awk -F'[:${]+' '{print $NF "\thook:" $1}'
    # test cfg keys
    local f
    for f in tests/*.sh; do
        [ "$f" = tests/t11-docs.sh ] && continue
        grep -noE '\bcfg[[:space:]]+[A-Z][A-Z0-9_]+' "$f" | awk -F'[: ]+' -v f="$f" '{print $NF "\t" f ":" $1}'
    done
}
# setup.sh keys that are not .env settings by design
NON_ENV_KEYS=" "
mapfile -t CODE_KEYS < <(code_keys | sort -u -k1,1 | cut -f1)
t_ge "configuration keys read by the code (count)" 20 "${#CODE_KEYS[@]}"

readme_config_section() { md_section README.md '^## Configuration reference' | sed -E 's/^[0-9]+://'; }
README_CFG="$(readme_config_section)"
# README documents the DB_ and REDIS_ account keys as "(same for `DB_` and `REDIS_`)".
readme_has_key() {
    local k="$1" text="$2"
    grep -qF "\`$k\`" <<<"$text" && return 0
    if [[ "$k" =~ ^(DB|REDIS)_(RUN_USER|UID|GID)$ ]] && grep -qF 'same for `DB_` and `REDIS_`' <<<"$text"; then
        grep -qF "\`APP_${BASH_REMATCH[2]}\`" <<<"$text" && return 0
    fi
    return 1
}
chk_keys_example() {
    local k where
    while IFS=$'\t' read -r k where; do
        grep -qE "^${k}=" .env.example || echo "${where}: key $k is read by the code but missing from .env.example"
    done < <(code_keys | sort -u -k1,1)
}
findings_check "every key the code reads is in .env.example" chk_keys_example
chk_keys_readme() {
    local k where
    while IFS=$'\t' read -r k where; do
        readme_has_key "$k" "$README_CFG" || echo "README.md: key $k (read at ${where}) is missing from the 'Configuration reference' (backticked)"
    done < <(code_keys | sort -u -k1,1)
}
findings_check "every key the code reads is in README's configuration reference" chk_keys_readme
chk_example_readme() {
    local k ln
    while IFS=: read -r ln k; do
        readme_has_key "$k" "$(cat README.md)" || echo ".env.example:$ln: key $k does not appear (backticked) in README.md"
    done < <(grep -nEo '^[A-Z][A-Z0-9_]*=' .env.example | sed 's/=$//')
}
findings_check "every .env.example key appears in README.md" chk_example_readme
chk_example_stale() {  # keys in .env.example that no code reads
    local k ln
    while IFS=: read -r ln k; do
        printf '%s\n' "${CODE_KEYS[@]}" | grep -qx "$k" || echo ".env.example:$ln: key $k is not read by setup.sh, the hook or any test"
    done < <(grep -nEo '^[A-Z][A-Z0-9_]*=' .env.example | sed 's/=$//')
}
findings_check ".env.example defines no key that nothing reads" chk_example_stale

# ===========================================================================
# 3. Dead references
# ===========================================================================
chk_dead_refs() {
    py "${DOCS[@]}" <<'PY'
import re, sys
# (pattern, allowlist regex applied to the line and its neighbours, or None = never allowed)
# Allowlist justification: README/AGENTS legitimately say that compose is GONE
# ("no compose file", "There is no `compose.yaml`") and that the up/restart path
# removes containers left by an old podman-compose setup (with `--depend`).
HIST = re.compile(r"legacy|old podman-compose|no compose file|compose-era|instead of compose|not compose|no `?compose\.yaml`?|--depend|earlier podman-compose", re.I)
NEG_VOL = re.compile(r"no (separate )?`?nextcloud-data`?|no longer exists|not `?nextcloud-data`?", re.I)
rules = [
    (r"compose\.yaml", HIST), (r"podman-compose", HIST),
    (r"nextcloud-data", NEG_VOL),
    (r"CONTAINER_HOST_PATH", None), (r"\.badhrc", None), (r"helixcode", None),
    (r"x-nextcloud-image", None), (r"\b8280\b", None),
]
for f in sys.argv[1:]:
    lines = open(f, encoding="utf-8").read().split("\n")
    for i, line in enumerate(lines):
        for pat, allow in rules:
            if re.search(pat, line):
                ctx = " ".join(lines[max(0, i-1):i+2])
                if allow is not None and allow.search(ctx):
                    continue
                print(f"{f}:{i+1}: dead reference /{pat}/: {line.strip()[:110]}")
PY
}
findings_check "docs contain no dead references (compose.yaml, podman-compose, nextcloud-data volume, helixcode, 8280, ...)" chk_dead_refs

# ===========================================================================
# 4. Backticked repo paths exist
# ===========================================================================
chk_paths() {
    py README.md AGENTS.md $([ -r tests/README.md ] && echo tests/README.md) <<'PY'
import os, re, sys, glob
top = set(os.listdir("."))
# Created at run time (not in a fresh checkout): tls/, .run/, backups/, data/,
# .env, .env.pre-restore.*, and test evidence directories written by the runner.
generated = {"tls", ".run", "backups", "data", ".env"}
for f in sys.argv[1:]:
    fence = False
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fence = not fence; continue
        if fence: continue
        for span in re.findall(r"`([^`\n]+)`", line):
            tok = span.split()[0]
            tok = tok[2:] if tok.startswith("./") else tok
            if tok.startswith(("/", "~", "-", "$", "http")):
                continue
            first = tok.split("/")[0]
            repo_like = "/" in tok or re.search(r"\.(sh|in|md|yaml|yml)$|^(Caddyfile|Containerfile)$", tok)
            if not repo_like or not (first in top or first in generated):
                continue
            if first in generated or first.startswith(".env"):
                continue
            if tok.endswith(".php"):
                continue  # config/config.php etc. are paths INSIDE the nextcloud-html volume
            if re.match(r"(tests|docs)/evidence", tok):
                continue
            # cut at the first placeholder/glob, keep the existing prefix
            cut = re.split(r"[<*${\[(]", tok)[0].rstrip(".")
            if cut != tok: cut = cut.rsplit("/", 1)[0] if "/" in cut and not cut.endswith("/") else cut
            cut = cut.rstrip("/")
            if cut and not os.path.exists(cut):
                print(f"{f}:{n}: stale path `{tok}` ('{cut}' does not exist)")
PY
}
findings_check "every backticked repo path in the docs exists (or is runtime-generated)" chk_paths

# ===========================================================================
# 5. systemd unit names
# ===========================================================================
if systemctl --user show-environment >/dev/null 2>&1; then
    chk_units_doc() {
        local u f ln
        grep -noE 'nextcloud-[a-z]+\.service' "${DOCS[@]}" 2>/dev/null | while IFS=: read -r f ln u; do
            systemctl --user cat "$u" >/dev/null 2>&1 || echo "$f:$ln: documented unit $u does not exist (systemctl --user cat)"
        done
    }
    findings_check "every nextcloud-*.service named in the docs exists" chk_units_doc
    chk_units_live() {
        local u
        while read -r u; do
            grep -qF "\`$u\`" README.md || echo "README.md: live unit $u is not documented (backticked)"
        done < <(systemctl --user list-units 'nextcloud-*.service' --all --plain --no-legend 2>/dev/null | awk '{print $1}')
    }
    findings_check "every live nextcloud-*.service unit is documented in README.md" chk_units_live
else
    t_skip "documented units exist" "systemd --user not reachable"
    t_skip "live units are documented" "systemd --user not reachable"
fi

# ===========================================================================
# 6. Ports and images
# ===========================================================================
default_of() { sed -nE "s/^readonly $1=\"([^\"]*)\".*/\1/p" setup.sh | head -1; }
HTTP_DEF="$(default_of DEFAULT_HTTP_PORT)"; HTTPS_DEF="$(default_of DEFAULT_HTTPS_PORT)"
t_match "DEFAULT_HTTP_PORT / DEFAULT_HTTPS_PORT parsed from setup.sh" '^[0-9]+ [0-9]+$' "$HTTP_DEF $HTTPS_DEF"
chk_ports() {
    local f k def v ln
    for k in NEXTCLOUD_PORT NEXTCLOUD_HTTPS_PORT; do
        def="$HTTP_DEF"; [ "$k" = NEXTCLOUD_HTTPS_PORT ] && def="$HTTPS_DEF"
        v="$(sed -n "s/^$k=//p" .env.example)"
        [ "$v" = "$def" ] || echo ".env.example: $k=$v but setup.sh default is $def"
        ln="$(grep -nE "^\| \`$k\` \|" README.md | head -1)"
        if [ -z "$ln" ]; then echo "README.md: no table row for $k"
        else [[ "$ln" == *"| \`$def\` |"* ]] || echo "README.md:${ln%%:*}: default of $k is not $def (${ln#*:})"; fi
    done
    # any host:port quoted in the docs must be one of the defaults or a protocol port
    py "$HTTP_DEF" "$HTTPS_DEF" "${DOCS[@]}" .env.example <<'PY'
import re, sys
ok = {sys.argv[1], sys.argv[2], "80", "443"}
for f in sys.argv[3:]:
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        for m in re.finditer(r"(?:localhost|127\.0\.0\.1|<[a-z-]+>|[a-z]+\.local|https?://[A-Za-z0-9.<>-]+):(\d{2,5})\b", line):
            if m.group(1) not in ok:
                print(f"{f}:{n}: port {m.group(1)} is neither DEFAULT_HTTP_PORT nor DEFAULT_HTTPS_PORT: {line.strip()[:90]}")
PY
}
findings_check "documented default ports equal setup.sh DEFAULT_HTTP_PORT/DEFAULT_HTTPS_PORT" chk_ports
chk_images() {
    local var img short
    for var in NEXTCLOUD DB REDIS CADDY HELPER; do
        img="$(default_of "DEFAULT_${var}_IMAGE")"
        [ -n "$img" ] || { echo "setup.sh: DEFAULT_${var}_IMAGE not found"; continue; }
        short="${img#docker.io/library/}"
        grep -qF "$short" README.md || echo "README.md: default image '$short' (DEFAULT_${var}_IMAGE) is not mentioned"
    done
    # a documented tag that differs from the default (upgrade examples are exempt)
    local f ln fam def
    for fam in mariadb redis nextcloud-caddy-brotli; do
        def="$(grep -oE "\"[^\"]*${fam}:[^\"]+\"" setup.sh | head -1 | sed -E 's/.*:([^"]+)"/\1/')"
        grep -noE "${fam}:[0-9]{1,2}[0-9A-Za-z.-]*" "${DOCS[@]}" | grep -vE "redis:[0-9]{4,}" | while IFS=: read -r f ln t; do
            [ "${t#*:}" = "$def" ] || echo "$f:$ln: $t differs from the default tag '$def'"
        done
    done
}
findings_check "documented image defaults equal setup.sh DEFAULT_*_IMAGE" chk_images

# ===========================================================================
# 7. Markdown quality
# ===========================================================================
chk_toc() {
    py <<'PY'
import re, unicodedata
fence = False; heads = []; toc = []
slugs = {}
for n, line in enumerate(open("README.md", encoding="utf-8"), 1):
    if line.lstrip().startswith("```"):
        fence = not fence; continue
    if fence: continue
    m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
    if m:
        t = m.group(2)
        t = re.sub(r"<[^>]+>", "", t)
        s = t.lower()
        s = re.sub(r"[^\w\- ]", "", s, flags=re.U).replace(" ", "-")
        k = slugs.get(s, 0); slugs[s] = k + 1
        heads.append((len(m.group(1)), n, s if k == 0 else f"{s}-{k}", t))
    m = re.match(r"^\s*[-*]\s+\[(.*)\]\(#([^)]+)\)", line)
    if m: toc.append((n, m.group(2), m.group(1)))
anchors = {h[2] for h in heads}
if not toc: print("README.md: no table of contents found")
for n, a, t in toc:
    if a not in anchors:
        print(f"README.md:{n}: TOC entry '{t}' -> #{a} matches no heading")
tocset = {a for _, a, _ in toc}
for lvl, n, s, t in heads:
    if lvl == 2 and s not in tocset and t.lower() != "table of contents":
        print(f"README.md:{n}: '## {t}' is not listed in the table of contents")
PY
}
findings_check "README table of contents resolves to headings (GitHub anchors) and lists every section" chk_toc

chk_fences() {
    local f c
    for f in "${DOCS[@]}"; do
        c="$(grep -cE '^[[:space:]]*```' "$f")"
        [ $((c % 2)) -eq 0 ] || echo "$f: unbalanced code fences ($c fence lines)"
    done
}
findings_check "fenced code blocks are balanced in README.md, AGENTS.md and tests/README.md" chk_fences
[ -r tests/README.md ] || t_skip "tests/README.md checks" "tests/README.md does not exist yet"

chk_tables() {
    py "${DOCS[@]}" <<'PY'
import re, sys
def pipes(s):
    return len(re.findall(r"(?<!\\)\|", s.strip().strip("|"))) + 1
for f in sys.argv[1:]:
    fence = False; start = None; cols = None
    def end(): pass
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fence = not fence; start = None; continue
        if fence: continue
        if line.startswith("|"):
            if start is None:
                start, cols = n, pipes(line)
            elif pipes(line) != cols:
                print(f"{f}:{n}: table row has {pipes(line)} cells, header (line {start}) has {cols}")
            if not line.rstrip().endswith("|"):
                print(f"{f}:{n}: table row is not closed with a trailing pipe")
        else:
            start = None
PY
}
findings_check "markdown tables are well formed (consistent cell counts, closed rows)" chk_tables

chk_placeholders() {
    grep -nE '\b(TODO|FIXME|XXX)\b' "${DOCS[@]}" | sed 's/^/placeholder: /'
}
findings_check "no TODO/FIXME/XXX placeholders in the docs" chk_placeholders

chk_asof() {
    local f
    for f in "${DOCS[@]}"; do
        # a line (or the one before it, for wrapped sentences) must carry an ISO date
        awk -v f="$f" 'tolower($0) ~ /(^|[^a-z])as of([^a-z]|$)/ { ctx = prev " " $0
                if (ctx !~ /[0-9]{4}-[0-9]{2}-[0-9]{2}/) print f ":" NR ": undated \"as of\" statement: " substr($0,1,90) }
            { prev = $0 }' "$f"
    done
    # the Verified state section must carry a date
    if ! md_section README.md '^## Verified state' | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        echo "README.md: 'Verified state' section carries no ISO date, so its figures cannot be dated"
    fi
}
findings_check "figures stated 'as of' carry a date; README 'Verified state' is dated" chk_asof

# ===========================================================================
# 8. Process / ownership claims need the cron exception
# ===========================================================================
chk_claims() {
    py "$HELP_TXT" "${DOCS[@]}" <<'PY'
import sys, re
import re, sys
ABS = re.compile(r"no process runs as a sub-?uid|nothing (is )?(ever )?written by a sub-?uid|no sub-?uid|"
                 r"(every|all)( of)?( the)? (services?|containers?|processes)[^.]{0,60}\b(run|runs|are|is)\b[^.]{0,60}(as (you|your)|unprivileged|your user)|"
                 r"(entirely|fully|completely) unprivileged|all (processes|services) (are )?unprivileged", re.I)
EXC = re.compile(r"\bcrond?\b|\bcron\b", re.I)
for f in sys.argv[1:]:
    text = open(f, encoding="utf-8").read()
    lines = text.split("\n")
    # paragraphs = blank-line separated; the exception must be in the same paragraph
    i = 0
    while i < len(lines):
        if not lines[i].strip(): i += 1; continue
        j = i
        while j < len(lines) and lines[j].strip(): j += 1
        para = "\n".join(lines[i:j])
        m = ABS.search(para)
        if m and not EXC.search(para):
            ln = i + 1 + para[:m.start()].count("\n")
            # AGENTS.md states the rule itself: 'Do not claim "no process runs as a sub-uid"'
            if re.search(r"do not claim|never claim", para, re.I): pass
            else: print(f"{'setup.sh(help header)' if f.endswith('help.txt') else f}:{ln}: absolute claim without the cron exception: \"{m.group(0)[:70]}\"")
        i = j
PY
}
findings_check "unprivileged/ownership claims name the cron (crond = container-root) exception" chk_claims

# ===========================================================================
# 9. AGENTS.md verification commands exist
# ===========================================================================
chk_verif() {
    local ln line cmd sub f
    while IFS=: read -r ln line; do
        line="${line%%#*}"
        case "$line" in
            *"./setup.sh "*)
                sub="$(sed -nE 's#.*\./setup\.sh ([a-z-]+).*#\1#p' <<<"$line")"
                printf '%s\n' "${PRIMARIES[@]}" | grep -qx "$sub" || echo "AGENTS.md:$ln: './setup.sh $sub' is not a setup.sh command" ;;
        esac
        for f in $(grep -oE '(^|[ (])(\./)?(tests/[A-Za-z0-9_.-]+\.sh|setup\.sh|config/[A-Za-z0-9_./-]+\.sh|tls/site\.crt)' <<<"$line" | tr -d ' (' ); do
            f="${f#./}"
            [ -e "$f" ] || echo "AGENTS.md:$ln: '$f' does not exist"
            case "$f" in tests/*.sh) [ -x "$f" ] || echo "AGENTS.md:$ln: '$f' is not executable";; esac
        done
    done < <(awk '/^## Verification before claiming/ {on=1; next} on && /^## / {exit} on && /^```/ {f=!f; next} on && f {print NR ":" $0}' AGENTS.md)
}
findings_check "AGENTS.md verification commands reference existing subcommands and scripts" chk_verif
t_check "AGENTS.md has a verification command block" bash -c "awk '/^## Verification before claiming/ {on=1} on && /^\`\`\`/ {n++} END {exit !(n>=2)}' AGENTS.md"

# ===========================================================================
# 10. Test modules are described; named test files exist
# ===========================================================================
TESTDOC="$(md_section README.md '^## Testing' | sed -E 's/^[0-9]+://')"
[ -r tests/README.md ] && TESTDOC+=$'\n'"$(cat tests/README.md)"
chk_tests_described() {
    local f b
    for f in tests/t[0-9]*.sh tests/run-all.sh tests/smb-live-test.sh; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        grep -qF "$b" <<<"$TESTDOC" || echo "$f: not described by name in tests/README.md or README.md 'Testing'"
    done
}
findings_check "every tests/t*.sh module, run-all.sh and smb-live-test.sh is described in the docs" chk_tests_described
chk_tests_exist() {
    local n
    for n in $(grep -oE '\b(tests/)?(t[0-9]{2}-[a-z0-9-]+|run-all|smb-live-test|lib)\.sh\b' <<<"$TESTDOC" | sed 's#^tests/##' | sort -u); do
        [ -e "tests/$n" ] || echo "docs name tests/$n, which does not exist"
    done
    for n in $(grep -ohE '\btests/[A-Za-z0-9_./-]+\.sh\b' README.md AGENTS.md | sort -u); do
        [ -e "$n" ] || echo "README/AGENTS name $n, which does not exist"
    done
}
findings_check "every test file named in the docs exists" chk_tests_exist

# ===========================================================================
# 11. Documentation covers each user-visible feature
# ===========================================================================
ALLDOCS="$(cat "${DOCS[@]}")"
feature() {  # feature "description" 'ERE'
    if grep -qiE -- "$2" <<<"$ALLDOCS"; then t_pass "docs mention: $1"
    else t_fail "docs mention: $1" "no match for /$2/ in ${DOCS[*]}"; fi
}
feature "systemd --user units"                       'systemctl --user'
feature "keep-id / file ownership"                   'keep-id'
feature "ownership audit/migration"                  'ownership'
feature "SMB live test (tests/smb-live-test.sh)"     'smb-live-test'
feature "uninstall command"                          '\./setup\.sh uninstall'
feature "backup --quiesce"                           'backup --quiesce'
feature ".env.pre-restore"                           '\.env\.pre-restore'
feature "drift warning ('./setup.sh restart' to apply)" 'setup\.sh restart.{0,40}(apply|take effect)|(apply|take effect).{0,60}setup\.sh restart|configuration changed since'
feature "NEXTCLOUD_MAINTENANCE_WINDOW_START"         'NEXTCLOUD_MAINTENANCE_WINDOW_START'
feature "HELPER_IMAGE"                               'HELPER_IMAGE'
feature "RunInit"                                    'RunInit'
feature "cron-root (sub-uid) exception"              'crond.{0,200}sub-?uid|sub-?uid.{0,200}crond'
feature "evidence reports"                           '(tests|docs)/evidence'
feature "host tuning advice (sysctl/limits)"         'sysctl|vm\.overcommit|swappiness|hugepage|somaxconn|nofile'

t_end
