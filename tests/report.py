#!/usr/bin/env python3
"""Turn a test evidence directory into results.json and report.md.

Usage: report.py EVIDENCE_DIR

Reads  results.jsonl  (one JSON object per check, written by tests/lib.sh)
       modules.jsonl  (one summary object per module)
       module-exit.tsv (module <TAB> exit code <TAB> seconds)
       environment.txt (free-form, included verbatim)
Writes results.json and report.md next to them. No third-party modules.
"""
import json
import os
import sys


def read_jsonl(path):
    out = []
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
    return out


def main(ev):
    checks = read_jsonl(os.path.join(ev, "results.jsonl"))
    modules = read_jsonl(os.path.join(ev, "modules.jsonl"))
    exits = {}
    p = os.path.join(ev, "module-exit.tsv")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                exits[parts[0]] = (int(parts[1]), parts[2])

    def exit_for(module_id):
        """Exit status of the module whose FILE STEM matches a t_begin id.

        t_begin ids and file names differ ('t01' vs 't01-static'): match exactly,
        else by the 'tNN' prefix.
        """
        if module_id in exits:
            return exits[module_id]
        for stem, val in exits.items():
            if stem == module_id or stem.startswith(module_id + "-") or module_id.startswith(stem.split("-")[0] + "-"):
                return val
        return (None, "")

    def count(status, module=None):
        return sum(1 for c in checks if c["status"] == status and (module is None or c["module"] == module))

    totals = {s.lower(): count(s) for s in ("PASS", "FAIL", "SKIP")}
    totals["checks"] = totals["pass"] + totals["fail"] + totals["skip"]
    verdict = "PASS" if totals["fail"] == 0 and all(rc == 0 for rc, _ in exits.values()) and totals["pass"] > 0 else "FAIL"

    env = ""
    ep = os.path.join(ev, "environment.txt")
    if os.path.exists(ep):
        env = open(ep, encoding="utf-8", errors="replace").read().rstrip()

    result = {
        "verdict": verdict,
        "totals": totals,
        "modules": [
            {
                "module": m["module"], "title": m.get("title", ""),
                "pass": m["pass"], "fail": m["fail"], "skip": m["skip"], "ms": m["ms"],
                "exit_code": exit_for(m["module"])[0],
            }
            for m in modules
        ],
        "failures": [
            {k: c[k] for k in ("module", "seq", "description", "command", "rc", "output", "time")}
            for c in checks if c["status"] == "FAIL"
        ],
        "checks": checks,
    }
    with open(os.path.join(ev, "results.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=1, ensure_ascii=False)

    lines = []
    w = lines.append
    w("# Test evidence report")
    w("")
    w(f"**Verdict: {verdict}** — {totals['pass']} passed, {totals['fail']} failed, {totals['skip']} skipped "
      f"({totals['checks']} checks in {len(modules)} modules)")
    w("")
    w("| Module | Title | Pass | Fail | Skip | Time | Exit |")
    w("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for m in result["modules"]:
        w(f"| `{m['module']}` | {m['title']} | {m['pass']} | {m['fail']} | {m['skip']} | "
          f"{m['ms'] / 1000:.1f}s | {m['exit_code']} |")
    w("")
    if result["failures"]:
        w("## Failures")
        w("")
        for f in result["failures"]:
            w(f"- **{f['module']} #{f['seq']}** {f['description']}")
            if f["command"]:
                w(f"  - command: `{f['command'][:200]}`")
            if f["output"]:
                w("  - output: `" + f["output"][:300].replace("`", "'").replace("\n", " ⏎ ") + "`")
        w("")
    skipped = [c for c in checks if c["status"] == "SKIP"]
    if skipped:
        w("## Skipped checks")
        w("")
        for c in skipped:
            w(f"- {c['module']}: {c['description']} — {c['output']}")
        w("")
    w("## All checks")
    w("")
    cur = None
    for c in checks:
        if c["status"] == "INFO":
            continue
        if c["module"] != cur:
            cur = c["module"]
            w(f"### {cur}")
            w("")
        mark = {"PASS": "✅", "FAIL": "❌", "SKIP": "⏭"}.get(c["status"], c["status"])
        w(f"- {mark} {c['description']}" + (f" _({c['ms']} ms)_" if c.get("ms") else ""))
    w("")
    if env:
        w("## Environment")
        w("")
        w("```")
        w(env)
        w("```")
        w("")
    w("## Integrity")
    w("")
    w("Every file in this directory is listed with its SHA-256 in `MANIFEST.sha256` "
      "(verify with `sha256sum -c MANIFEST.sha256`). `results.jsonl` holds one record per check "
      "(command, exit status, duration, redacted output); `logs/` holds the full per-module logs; "
      "`console/` the raw console output. Secrets are redacted everywhere.")
    with open(os.path.join(ev, "report.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: report.py EVIDENCE_DIR")
    sys.exit(main(sys.argv[1]))
