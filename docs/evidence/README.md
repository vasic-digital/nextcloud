# Test evidence

Machine-generated evidence from complete live runs of the test suite (`tests/run-all.sh`),
published with `tests/publish-evidence.sh` only after the run passed, its manifest verified and
a scan found no secrets.

| Run | Commit under test | Verdict |
| --- | --- | --- |
| `2026-10-19-b6a9c73/` | `b6a9c73` (clean working tree) | PASS, 11 modules, 0 failed |

Inside a run directory:

- `report.md` — verdict, per-module table, every check, environment
- `results.json` / `results.jsonl` — every check with command, exit status, duration and redacted output
- `environment.txt` — host, tool versions, git commit, image digests, unit states, SHA-256 of the code under test
- `logs/`, `console/` — full per-module logs and console output (secrets redacted)
- `MANIFEST.sha256` — SHA-256 of every file; verify with:

```bash
cd docs/evidence/2026-10-19-b6a9c73 && sha256sum -c MANIFEST.sha256
```

See [tests/README.md](../../tests/README.md) for what each module proves and how to produce a new run.
