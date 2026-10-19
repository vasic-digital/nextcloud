# Test suite

A **live** test suite for the LAN-only Nextcloud stack (five `systemctl --user`
Quadlet units rendered by `setup.sh`). It exercises the real units, containers,
volumes, certificates and the real Nextcloud API, and it writes machine-generated
**evidence** for every run. The user-level documentation is
[README.md](../README.md); the constraints for agents are in
[AGENTS.md](../AGENTS.md).

Contents: [Running](#running) · [Modules](#modules) · [SMB live test](#smb-live-test) ·
[Evidence](#evidence) · [Library API](#library-api) · [Writing a module](#writing-a-module) ·
[Rules](#rules-for-tests) · [Credentials](#credentials) · [Exit codes and runtime](#exit-codes-and-runtime) ·
[Reading a failure](#reading-a-failure)

## Running

```bash
tests/run-all.sh                    # everything, including the destructive modules
tests/run-all.sh --non-destructive  # skip t07-resilience and t08-backup-restore
tests/run-all.sh --quick            # also skip the slow cron wait (implies --non-destructive)
tests/run-all.sh --only t03,t04     # only these modules (ids such as t03, or full names)
tests/run-all.sh --skip t05,t07     # everything except these
tests/run-all.sh --list             # print the module names in run order and exit
tests/run-all.sh --evidence-dir DIR # write the evidence here instead of tests/evidence/<UTC time>
tests/t11-docs.sh                   # any single module can be run on its own
```

`tests/run-all.sh` needs `python3`, `curl`, `podman`, `systemctl` and `sha256sum`,
and the stack must already be running (`./setup.sh up`); otherwise it exits with
status 2 before running anything. A module run on its own prints where it wrote its
(temporary) evidence at the end.

Run order is fixed and deliberate: read-only modules first, then functional ones,
then the destructive ones, then the documentation check (`t11-docs` last, so it
sees the final state of the tree):

`t01-static`, `t09-dynamic`, `t02-units`, `t03-ownership`, `t10-security`,
`t04-https`, `t06-nextcloud`, `t05-smb`, `t07-resilience`, `t08-backup-restore`,
`t11-docs`.

`--quick` and `--non-destructive` both drop `t07-resilience` and
`t08-backup-restore`. `--quick` additionally exports `T_QUICK=1`, which makes
`t06-nextcloud` skip the wait for the cron job to advance `lastcron`.

**The destructive modules restart services, stop the database, uninstall and
reinstall the units, destroy the instance and restore it.** They put the stack
back (an `EXIT` trap restores `.env` and starts it again, also on failure), but do
not run them on an instance whose data you have no backup of, and do not run them
while other people are using it.

## Modules

Each module is `tests/tNN-<name>.sh`, sources [lib.sh](lib.sh) and ends with
`t_end`. "Negative control" below means a check that proves the test can fail: a
deliberately broken input must be rejected, otherwise the positive check proves
nothing.

| Module | Disruptive | What it proves |
| --- | --- | --- |
| `t01-static.sh` | no | Static analysis of the repository (renders into throw-away directories only). |
| `t02-units.sh` | no | The five Quadlet units and the network unit exist, run and are wired correctly. |
| `t03-ownership.sh` | no (writes unique temp entries and removes them) | Every process and every file of the stack belongs to the invoking user. |
| `t04-https.sh` | no | The Caddy TLS front end, the certificate, HTTP/2, HTTP/3, compression and the plain HTTP port. |
| `t05-smb.sh` | no (briefly changes ownership of one directory and restores it) | The live SMB test passes, and fails against the old sub-uid ownership. |
| `t06-nextcloud.sh` | no (one unique collection, always removed) | Nextcloud works through HTTPS: WebDAV, OCS, host-disk consistency, Redis, MariaDB, hook settings, cron. |
| `t07-resilience.sh` | **yes** | Lifecycle: idempotent `up`, drift, self-healing, boot order, `uninstall`/reinstall, busy port, legacy containers, bad configuration. |
| `t08-backup-restore.sh` | **yes** | `backup --quiesce`, corrupt-backup refusal, `restore` onto live volumes, then `destroy` and restore from nothing. |
| `t09-dynamic.sh` | no | `setup.sh` functions against synthetic configuration: nothing is hard-coded. |
| `t10-security.sh` | no | Secrets handling, least privilege, exposure, hardening. |
| `t11-docs.sh` | no | The documentation matches the code. |

### t01-static

- Syntax: `bash -n` for `setup.sh` and every `tests/*.sh`, `sh -n` for the container
  hook, `shellcheck --severity=error` when installed (skipped otherwise), each with a
  negative control.
- Hook file mode (executable, not world-writable) and the five hook subdirectories.
- Templates: every `@TOKEN@` in `systemd/*.in` is substituted by `render_units` and
  every substitution is used; templates render into a temp directory with no
  placeholder left; `quadlet -dryrun -user` accepts the result (and rejects an
  invalid unit); the **live** rendered units equal what `setup.sh` would render now
  (no stale unit, no stray `nextcloud*` file).
- A hard-coding audit of `setup.sh`, the templates, the Caddyfile, the Containerfile,
  the hook and the tests: no literal uid/gid, user name, path, subnet, host name or
  port outside a justified allowlist, with a negative control per class.
- `.env.example` documents every key the code reads and holds no orphan key.
- Git hygiene: `.env`, `.run/`, `tls/`, `backups/`, `data/` are ignored and not
  tracked; a scan of tracked and addable files finds no live secret value.
- File modes: `.env` 600, `.run` 700, `.run/*.env` 600, `tls/site.key` 600.
- No compose remnants in the tree or in `setup.sh`.

### t02-units

Read-only. Unit files are generated from Quadlet sources; every unit is
`active (running)`, the network unit is `active (exited)` and the Podman network has
a subnet; `Restart=always`; wanted by `default.target`; lingering is enabled. The
dependency graph: `app` Requires and orders after `db` and `redis`, `cron` Requires
`app`, `caddy` only Wants `app` (a web restart must not stop TLS), everything starts
after the network. Containers carry their `PODMAN_SYSTEMD_UNIT` label, are not
compose containers, are running, all five services report `healthy` (the test waits for it) and no
`nextcloud-*` unit is failed. Each container runs the configured image and `app` and
`cron` run the same one. Negative controls prove the cron and caddy healthchecks can fail (the cron
pattern is `[c]rond` so it cannot match its own command line). A 10 second sampling
window proves nothing is in a restart loop. Published ports: exactly HTTP `bind:port -> 80/tcp` on `app` and
`bind:port -> 443` tcp+udp on `caddy`, nothing else on any container, the host really
listens on those sockets, and the whole stack publishes exactly three. User
namespaces are `keep-id:uid=N,gid=N` for every service except `caddy`.

### t03-ownership

- Processes: every process of `db`, `redis`, `app` and `caddy` runs as the invoking
  host uid (caddy's container-root maps to it). **The one documented exception is
  `cron`**: its `crond` supervisor and the init (`RunInit=yes`) run as container-root,
  which under `keep-id` is a host sub-uid; the test requires that this is a single
  sub-uid, that no process runs as host root, that the only such processes are the
  init and busybox `crond`, and that every job child runs as the invoking uid.
- The numeric ids in each unit's `UserNS=` equal the account's ids read from the
  image.
- Files: the data directory, the Quadlet files and all four volumes hold no entry
  owned by another user or group; the html volume's `data` mount point is yours.
- `foreign_owned` has a positive and a negative control (a deliberately foreign-owned
  tree is detected; a tree you created is not).
- Write-through in both directions: files created, modified and deleted by the host
  are seen and changeable by the container and the other way round, always owned by
  the invoking user.
- `./setup.sh status` prints the ownership section with `0 entries not owned` and all
  four volumes `ok`.

### t04-https

Non-disruptive GET/HEAD requests. For every name the certificate must cover
(`localhost`, `127.0.0.1`, the host name, `<host>.local`, the LAN IP and the trusted
domains): TLS verifies against `tls/site.crt`, `/login` answers 200 over HTTP/2 with a
non-trivial body (regression test for the blank page), and a name that is not in the
certificate is rejected. The served certificate fingerprint equals `tls/site.crt`,
its SANs, validity window, key size/curve and signature algorithm are sane. An
unknown `Host` header gets Nextcloud's 400 untrusted-domain page, not an empty 200.
Compression is negotiated (`br`, `gzip`, `zstd`) and decodes to the identity bytes;
HTTP/3 works when curl supports it (skipped otherwise) and `alt-svc` advertises
`h3`. HTTPS pages contain no `http://` self-links; the **CalDAV/CardDAV
`/.well-known/` redirects do not downgrade to http**. `TRUSTED_PROXIES` equals the
network subnet and `overwriteprotocol` is unset. Plain HTTP still works and does not
force `https://`; no plaintext HTTP is served on the TLS port; port 80 is not
published. Twenty sequential requests all return 200.

### t05-smb

Runs [smb-live-test.sh](smb-live-test.sh) twice (same totals both times, no leftovers
in the Nextcloud user's files directory), then runs a negative control: it hands that
directory to a sub-uid (the state that used to cause `NT_STATUS_ACCESS_DENIED`),
requires the SMB test to **fail** with that error, restores the ownership and
requires it to pass again. It is skipped (not failed) when `smbclient` is missing or
`SMB_TEST_USER` / `SMB_TEST_PASSWORD` are not set.

### t06-nextcloud

Through HTTPS as the `.env` administrator: `status.php` (installed, not in
maintenance, no pending upgrade), `occ status`, background-jobs mode `cron`,
`files:scan` with 0 errors, `integrity:check-core`, and the hook-applied settings
(`filesystem_check_changes`, `maintenance_window_start` equal to
`NEXTCLOUD_MAINTENANCE_WINDOW_START`, `lost_password_link`). A WebDAV matrix in one
unique collection: MKCOL, PUT (text, 1 MiB and 8 MiB binary, unicode and space in the
name), GET with sha256 comparison, PROPFIND sizes, ETag and conditional GET (304),
Range GET (206), overwrite (204), COPY, MOVE, DELETE and 404s. The same files are
checked on the host disk (content and owner), and host-side append, create and delete
become visible through WebDAV. Negative paths: unauthenticated or wrong-password
requests give 401 and create nothing. OCS capabilities and user endpoints. Redis
classes for distributed cache and locking, `PONG`, redis PHP session handler, keys in
Redis; MariaDB answers with a full schema. Finally `lastcron` is recorded and must
advance within 330 seconds (skipped by `--quick`) and be younger than six minutes.

### t07-resilience (disruptive)

1. `up` on a running stack is idempotent (container ids unchanged, no drift warning).
2. Editing `.env` makes the next `up` print the drift warning (`run ./setup.sh restart`
   to apply it) **without** applying it; `restart` applies it through
   `.env` to the env files to the hook; the value is then reverted.
3. Killed processes are restarted by systemd.
4. Restarting the database brings its dependants back.
5. `cron` stops promptly and is not reported failed (`RunInit=yes`, exit 143 accepted).
6. All units started at once in the worst order still converge (boot is parallel).
7. `uninstall` removes units, containers and `.run/` but keeps the volumes, `.env`,
   `tls/` and the user data; `up` brings back the same instance id and file, with
   no restart loop.
8. A busy port is refused (`already in use`) before anything starts.
9. A leftover non-Quadlet container named like a stack container is replaced, an
   unrelated `nextcloud-*` container is left alone.
10. A relative `DATA_HOST_PATH` and the `change-me` placeholder are refused with a clear
    message, without touching the running stack.

### t08-backup-restore (destructive)

Fixtures (text, binary, unicode and nested files, extra users) are created first.
`backup --quiesce` must enter and leave maintenance mode and yield a mode 0700
directory with a valid `database.sql.gz`, `data.tar.gz`, `config.tar.gz` (containing
`config/config.php`, archived before maintenance mode is entered), a mode 0600 `env.backup` and `systemd.backup/`. Everything is
then mutated. Bad backups are refused before anything is touched (corrupt archive,
incomplete set, missing `config.php`; data and container ids unchanged);
`newest_backup` ignores an incomplete newer directory; a failed backup leaves no
partial directory. `restore` onto the live volumes returns the **same instance id**,
the original files, byte-identical binaries, the earlier user, the same table count,
a working administrator login and a saved `.env.pre-restore.<timestamp>` (mode 0600),
with correct ownership and maintenance mode off. Then a plain backup, `destroy` (no container or volume left,
`.env` and the data directory kept), a plain `up` that is **refused** because the
data directory is not empty and starts nothing, and `restore` from nothing: same
instance id, files, user, login, tables, cron running, app healthy.

### t09-dynamic

Calls `setup.sh` functions (sourced, never executed) with synthetic `.env` files and
throw-away `NEXTCLOUD_ENV_FILE` / `NEXTCLOUD_RUN_DIR` / `NEXTCLOUD_QUADLET_DIR`; the
live stack is only read. Ten groups: identity discovery equals independent ground
truth from the images; `.env` overrides take precedence (and reach `app` and `cron`
together); rendering variants (ports, bind, images, paths, buffer pool); `data_path`;
`env_get`/`env_or`/`env_need`/`image_of`/`sed_esc` edge cases; `probe_host`;
`write_env_files` (per-service least privilege, `TRUSTED_PROXIES` from the network or
the override); `ensure_env` (generated secrets, placeholders, trusted domains);
`ensure_tls` (SANs follow the configuration, regeneration on change); naming helpers.
Negative controls prove the functions would notice wrong values.

### t10-security

File modes and owners of `.env`, `.run/` and `tls/`; secrets reach only the
containers that need them (the DB root password only in `db`, and **no admin password
in any running container**, which proves the first-install credentials were scrubbed);
`TRUSTED_PROXIES` equals the real subnet and has no catch-all; no container publishes
anything beyond the three configured sockets and the bind address is honoured; no
container is privileged, adds capabilities, devices, host namespaces, `unconfined`
options or a container-engine socket; every host bind mount is on an allowlist and
`Caddyfile`, `tls` and the hooks are read-only; the Caddyfile only reverse-proxies;
the TLS endpoint presents the generated certificate and offers no plain HTTP;
Nextcloud settings (`overwriteprotocol` unset, `lost_password_link` disabled, no
bogus `trustedProxies*` keys in `config.php`); secret paths are untracked and ignored.

### t11-docs

Read-only (about 7 seconds). The documentation must match the code; each check
collects `file:line` findings and fails when there are any:

- every dispatch command and alias in `setup.sh` is in the `help` header and in the
  README command table, and nothing is documented that does not exist;
- every configuration key the code reads is in `.env.example` and in the README
  configuration reference, and `.env.example` has no key nothing reads;
- no dead references (the removed compose file and tooling, obsolete ports and
  volume names, and similar), every backticked repo path exists, every `nextcloud-*.service` named in
  the docs exists and every live unit is documented;
- documented default ports and image tags equal the defaults in `setup.sh`;
- the README table of contents resolves and lists every section, code fences are
  balanced, tables are well formed, there are no leftover placeholder markers,
  dated-figure statements carry an ISO date and the README "Verified state" is dated;
- absolute process-model claims name the cron (`crond`) exception;
- the verification commands in `AGENTS.md` exist;
- every test module is described by name in this file or in the README; and every
  user-visible feature (uninstall, `backup --quiesce`, `.env.pre-restore`, drift
  warning, maintenance window, `HELPER_IMAGE`, `RunInit`, evidence, host tuning)
  is mentioned.

## SMB live test

`tests/smb-live-test.sh [smb-host]` is an end-to-end test of the fix for
`NT_STATUS_ACCESS_DENIED`. As the Samba account it adds, modifies, renames and removes
files and directories (including a 1 MiB binary and nested directories) in the
Nextcloud user's folder over SMB, checks the on-disk owner of everything, confirms
Nextcloud sees SMB's changes over HTTPS/WebDAV, and does the reverse. Everything lives
in one throw-away directory that is removed at the end, on failure and on interrupt.
It prints `N passed, M failed` and exits 0 only when nothing failed (2 when it is not
configured). `t05-smb.sh` wraps it with a negative control.

## Evidence

Every run of `tests/run-all.sh` writes a directory, by default
`tests/evidence/<UTC time>` (git-ignored; `tests/evidence/latest` points at the newest):

| File | Content |
| --- | --- |
| `report.md` | Verdict, per-module table, failures, skipped checks, every check, the environment, integrity note. |
| `results.json` | The same, machine-readable: verdict, totals, modules, failures, all checks. |
| `results.jsonl` | One record per check: module, sequence, status, description, command, exit code, duration, redacted output (first 1500 characters), time. |
| `modules.jsonl` | One summary per module: pass/fail/skip counts and duration. |
| `module-exit.tsv` | Module, exit code, seconds (module names are file names, e.g. `t03-ownership`). |
| `environment.txt` | Host, kernel, user and uid map, Podman and systemd versions, git commit and dirty-path count, options used, unit states, containers, image digests and the SHA-256 of every file under test. |
| `logs/` | Full per-module logs and the captured output of each `setup.sh` call. |
| `console/` | Raw console output of every module. |
| `MANIFEST.sha256` | SHA-256 of every other file in the directory. |

The verdict is `PASS` only when no check failed, every module exited 0 and at least
one check passed. A skipped check is reported but does not fail the run.

Verify an evidence directory has not been altered:

```bash
cd tests/evidence/latest && sha256sum -c MANIFEST.sha256
```

A vetted run can be copied to `docs/evidence/<UTC date>-<git hash>/` with
`tests/publish-evidence.sh [DIR]`. It refuses unless the verdict is `PASS`, the
manifest verifies and no secret value occurs anywhere in the evidence, and it writes a
fresh manifest for the copy. Run it only on evidence from a full run you intend to
keep; figures quoted in the documentation should come from, and be dated like, such a
report.

### Secret redaction

`lib.sh` reads every value of a `*PASSWORD*` or `*SECRET*` key in the environment file
(`NEXTCLOUD_ENV_FILE`, default `.env`; values of at least six characters) and replaces
each occurrence by `<redacted>` in the console output, in `results.jsonl`, in the
per-module logs and in the per-call `setup.sh` captures. `run-all.sh` also redacts the
console stream and the environment snapshot. Modules must still never print a secret
on purpose: the redaction is a safety net, not permission.

## Library API

`tests/lib.sh` is sourced by every module (it encodes the JSON evidence records in pure bash, with no subprocess per check). It changes into the repository root, so
paths are relative to it, and creates an ephemeral evidence directory unless
`TEST_EVIDENCE_DIR` is set (as `run-all.sh` does).

| Function | Purpose |
| --- | --- |
| `t_begin ID "title"` | Start a module; prints the header and resets the counters. |
| `t_end` | Print the summary, record it in `modules.jsonl`, return non-zero if any check failed. Always the last line of a module. |
| `t_check "desc" cmd args...` | PASS when the command exits 0. The command runs in a subshell, so use named functions or `bash -c`. |
| `t_check_not "desc" cmd args...` | PASS when the command **fails**; the basis of negative controls. |
| `t_eq "desc" expected actual` | PASS when the strings are equal. |
| `t_ne "desc" unexpected actual` | PASS when they differ. |
| `t_match "desc" 'ERE' string` | PASS when the extended regex matches. |
| `t_nomatch "desc" 'ERE' string` | PASS when it does not. |
| `t_ge "desc" min actual` | PASS when the integer `actual >= min`. |
| `t_wait "desc" SECONDS cmd args...` | Poll once a second until the command succeeds; FAIL on timeout. Use it instead of `sleep`. |
| `t_pass "desc" [output]`, `t_fail "desc" [detail]`, `t_skip "desc" "reason"` | Record a verdict for logic that does not fit a single command. |
| `t_info "text"` | A note in the log; not counted. |
| `t_tmpdir` | A throw-away directory removed when the module exits. |
| `cfg KEY [default]` | Configuration lookup with the precedence of `setup.sh`: environment, then the env file, then `.env.example`. |
| `in_setup 'snippet'` | Run a snippet with `setup.sh` sourced (functions only; `main` does not run). Combine with `NEXTCLOUD_ENV_FILE`, `NEXTCLOUD_RUN_DIR`, `NEXTCLOUD_QUADLET_DIR`, `NEXTCLOUD_NO_RELOAD`. |
| `run_setup args...`, `run_setup_confirm WORD args...` | Run `./setup.sh`, leaving combined output in `$SETUP_OUT` and the status in `$SETUP_RC`; the second pipes a confirmation word (`RESTORE`, `DELETE`) to stdin. |
| `occ args...` | `./setup.sh occ ...` with output captured. |
| `t_services`, `t_unit NAME` | Service names exactly as `setup.sh` defines them; unit name of a service. |
| `stack_all_active`, `stack_web_ok`, `stack_healthy`, `stack_ctr_ids` | Stack state helpers (all units active; HTTP and HTTPS report installed; both; container ids, which change when a container is recreated). |
| `nc_admin_user`, `nc_admin_pass`, `nc_http_port`, `nc_https_port`, `data_dir`, `lan_ip` | Values of the live instance, read from `.env` or the system. |
| `https_curl args...`, `dav METHOD PATH args...` | curl against the live HTTPS endpoint with `tls/site.crt` as the CA; WebDAV as the administrator. |
| `redact`, `sha256_of`, `me_uid`, `me_user` | Filter secrets from stdin; SHA-256 of stdin; the invoking user. |

A failing `t_check` does not stop the module; every check runs and the module
fails at `t_end`.

## Writing a module

New behaviour in `setup.sh`, the units, the Caddyfile or the hook needs a check in
an existing module or a new `tests/tNN-<name>.sh`.

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
t_begin t12 "what this module proves"

T="$(t_tmpdir)"
t_eq "app unit restarts on failure" always \
    "$(systemctl --user show -p Restart --value "$(t_unit app)")"
t_check_not "negative control: a made-up path does not exist" \
    test -e "$T/no-such-file"

t_end
```

Then `chmod +x` it, add it to `MODULES` in `run-all.sh` (and to `DESTRUCTIVE` if it
changes the stack), and describe it in this file by name; `t11-docs` fails otherwise.
If the module changes the live stack it must restore it on every exit path with a
`trap`.

## Rules for tests

- **Deterministic**: no fixed `sleep`; wait for a condition with `t_wait`.
- **Self-cleaning**: use `t_tmpdir` and unique names (`$$`, `$RANDOM`), remove what you
  create, also on failure.
- **Never hard-code** a uid, gid, path, port, user name, subnet or host name. Read them
  from `.env`, `id`, the images or the Podman network. `t01-static` fails the run when
  such a literal appears in the tests.
- **Negative controls**: for every "this is absent/refused/denied" check, include a
  case showing the check can fail.
- **Never print a secret**, and never use a real secret as a test fixture; use random
  values.
- **Do not weaken a check** to make it pass; fix the cause or record a justified skip.

## Credentials

Only the SMB tests need credentials: `SMB_TEST_USER` and `SMB_TEST_PASSWORD` (the host
account Samba authenticates), optionally `SMB_TEST_SHARE` (default `Nextcloud`),
`SMB_TEST_HOST` (default: the LAN IP) and `NC_TEST_USER` (default: the administrator
from `.env`), set in the environment or in `.env`. They are never committed and are
redacted in the evidence. `smbclient` must be installed. Without them `t05-smb` is
skipped. All other modules use the administrator account already in `.env`.

## Exit codes and runtime

| Command | 0 | 1 | 2 |
| --- | --- | --- | --- |
| `tests/run-all.sh` | every module passed | a check or module failed | cannot start: stack not running, missing tool, unknown option |
| a module | no check failed | at least one check failed | cannot start |
| `tests/smb-live-test.sh` | every check passed | a check failed | not configured |

Runtime depends on the host. `t11-docs` took 6.1 s on 2026-10-20 on the reference
host. The non-destructive run is dominated by `t06-nextcloud` (the cron wait of up to
330 s, skipped by `--quick`) and the 10 s restart-loop window in `t02-units`. The
destructive modules restart the stack several times and rebuild it from nothing, so a
full run takes much longer than a non-destructive one; read the exact per-module times
from your own `module-exit.tsv` rather than from this page.

## Reading a failure

1. Open `report.md` in the evidence directory: **Failures** lists each failing check
   with its command and the first 300 characters of output.
2. The full story is in `logs/<module>.log` (all checks of the module, with the
   command and up to 60 output lines each) and `console/<module>.txt`; `setup.sh`
   calls made by a module are in `logs/<module>-setup-<n>.txt`. In `results.jsonl`
   `rc` is the command's exit status.
3. Re-run only that module (`tests/run-all.sh --only t03`, or the script directly).
4. Decide whether the code, the environment or the test is wrong. Typical causes:

| Failure | Usual cause |
| --- | --- |
| `t01` "live unit ... matches what setup.sh renders now" | Templates or `.env` changed without `./setup.sh restart` (or `install`). |
| `t01` hard-coding audit | A literal id, path, port or host name was added; read it from the system instead. |
| `t02` port, unit or health checks | A service is down or restarting: `./setup.sh status`, `journalctl --user -u nextcloud-<svc>`. |
| `t03` foreign-owned files | Files written by an older setup: `./setup.sh down && ./setup.sh up` migrates them. |
| `t04` blank page | The Caddyfile lost its site block; see the README, Reverse proxy. |
| `t05` fails to authenticate | Wrong `SMB_TEST_*`; or ownership regressed, which shows as `NT_STATUS_ACCESS_DENIED`. |
| `t07`/`t08` after an aborted run | The `EXIT` trap normally restores the stack; if not, `./setup.sh up`. |
| `t11` | The code changed and the documentation did not (or the reverse); the finding names `file:line`. |

Do not report the stack as working until `tests/run-all.sh` (at least
`--non-destructive`) ends with `Verdict: PASS` and the evidence verifies.
