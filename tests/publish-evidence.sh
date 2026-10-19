#!/usr/bin/env bash
# ===========================================================================
#  Publish a finished test run as committed evidence under docs/evidence/.
#
#  Usage:  tests/publish-evidence.sh [EVIDENCE_DIR]     (default: tests/evidence/latest)
#
#  Refuses to publish unless
#    * the run's verdict is PASS (report.md / results.json),
#    * MANIFEST.sha256 verifies (nothing was altered after the run),
#    * no secret value from .env (any *PASSWORD*/*SECRET* value, plus SMB_TEST_PASSWORD)
#      occurs anywhere in the evidence.
#  The copy is named  docs/evidence/<UTC date>-<git short hash>/  and gets its own
#  MANIFEST.sha256 so it can be verified in place.
# ===========================================================================
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT" || exit 2

SRC="${1:-$ROOT/tests/evidence/latest}"
[ -d "$SRC" ] || { echo "no such evidence directory: $SRC" >&2; exit 2; }
SRC="$(cd -- "$SRC" && pwd -P)"

die() { echo "REFUSED: $*" >&2; exit 1; }

# 1. verdict
python3 - "$SRC/results.json" <<'PYEOF' || die "the run did not pass (see $SRC/report.md)"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8", errors="replace"))
sys.exit(0 if d["verdict"] == "PASS" and d["totals"]["fail"] == 0 else 1)
PYEOF

# 2. integrity
( cd "$SRC" && sha256sum -c --quiet MANIFEST.sha256 ) || die "MANIFEST.sha256 does not verify: the evidence was modified after the run"

# 3. secrets
leak=0
while IFS= read -r line; do
    v="${line#*=}"
    [ "${#v}" -ge 6 ] || continue
    if grep -rqF -- "$v" "$SRC"; then leak=1; echo "secret value of $(printf '%s' "${line%%=*}") found in the evidence" >&2; fi
done < <(grep -E '^[A-Z_]*(PASSWORD|SECRET)[A-Z_]*=' .env 2>/dev/null)
[ "$leak" -eq 0 ] || die "secrets present in the evidence"

DEST="$ROOT/docs/evidence/$(date -u +%Y-%m-%d)-$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
[ ! -e "$DEST" ] || DEST="${DEST}-$(date -u +%H%M%S)"
mkdir -p "$DEST"
cp -a "$SRC"/. "$DEST"/
rm -f "$DEST/MANIFEST.sha256"
( cd "$DEST" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
( cd "$DEST" && sha256sum -c --quiet MANIFEST.sha256 ) || die "copy does not verify"
echo "Published: $DEST"
echo "Verify:    cd '$DEST' && sha256sum -c MANIFEST.sha256"
