# AGENTS.md — working in this repository

Agent-facing notes. `README.md` is the human-facing document and is authoritative
on *behaviour*; this file records the constraints that are easy to violate and
hard to notice.

## What this repository is

A private, **LAN-only** Nextcloud instance on **rootless Podman**, with no domain.
HTTPS is provided by a Caddy front end with a **self-signed** certificate. There
is no public exposure and adding one (public DNS, ACME, port forwarding) is out
of scope.

The stack is five **`systemctl --user` services** (Podman Quadlet) driven by
`setup.sh`. The unit *templates* are `systemd/*.in`; `setup.sh` renders them into
`~/.config/containers/systemd/` and Podman's generator turns them into
`nextcloud-<svc>.service`. There is **no compose file** any more.

| Service | Image | Notes |
| --- | --- | --- |
| `app` | `nextcloud:35-apache` | plain HTTP, published `${NEXTCLOUD_PORT:-8080} → 80` |
| `caddy` | `localhost/nextcloud-caddy-brotli:2` (built from `docker/caddy`, never pulled) | TLS terminator, published `${NEXTCLOUD_HTTPS_PORT:-52443} → 443` tcp+udp (HTTP/3); proxies to `app:80` |
| `db` | `mariadb:11` | **not** published to the host |
| `redis` | `redis:7-alpine` | cache + file locking + PHP sessions; **not** published |
| `cron` | same image as `app` | `entrypoint: /cron.sh` |

Units: `nextcloud-network.service`, `nextcloud-db`, `-redis`, `-app`, `-cron`, `-caddy`
(`.service`). All `Restart=always`, `WantedBy=default.target`, lingering enabled.
All five services have healthchecks: `db`/`redis` (`Notify=healthy`), `app`
(`curl status.php`), `caddy` (`wget` to Caddy's own admin API, independent of the app),
`cron` (a `/proc` loop for a live `crond`; the pattern is written `[c]rond` on purpose, a
plain `crond` matches the check's own command line and could never fail). `app`
`Requires=` db + redis; `cron` `Requires=` app; `caddy` only `Wants=` app.

`NEXTCLOUD_BIND` applies to **both** published ports (HTTP and HTTPS); there is no
HTTP-only bind. `setup.sh` refuses placeholder secrets (`change-me`) and a relative
`DATA_HOST_PATH`. Health probes use `NEXTCLOUD_BIND` (127.0.0.1 when it is `0.0.0.0`).

`app` and `cron` share one image value (`image_of nextcloud` in `setup.sh`,
default `DEFAULT_NEXTCLOUD_IMAGE`, override `NEXTCLOUD_IMAGE` in `.env`). **Change
that one value, never the rendered units** — it is what stops the two services
from drifting to different versions.

## Hard constraints

### 0. Nothing is hard-coded; everything runs as the invoking user

- **No literal uid, gid, path, port, subnet or user name** in `setup.sh`, the unit
  templates or the tests. The host user comes from `id`; each service account's
  uid/gid is read **from its image** (`service_ids`/`image_account_ids`), with
  optional `.env` overrides (`APP_/DB_/REDIS_` `RUN_USER`/`UID`/`GID`); the
  proxy subnet is read from the Podman network; images, ports, data path come from
  `.env`. Do not "simplify" any of this back into constants such as `33`, `999`,
  `1000`, `100032` or `10.89.0.0/16`.
- Every container uses `UserNS=keep-id:uid=<img uid>,gid=<img gid>`, so
  `www-data`/`mysql`/`redis` **are** the login user on the host. This is what makes
  files shared over Samba writable. `db`, `redis` and `app` are fully unprivileged.
  Two container-root processes exist: `caddy` (no `keep-id`, so its root **is** the
  login user) and `cron`'s `crond` (`User=root`, required by busybox `crond` for
  `setgroups()`; under `keep-id` that root is a host **sub-uid** that writes
  nothing, and the jobs it launches run as the web account = the login user).
  Invariant: **every process that writes files, and every file, belongs to you.**
  Do not claim "no process runs as a sub-uid".
- `app` runs non-root; the entrypoint's `redis-session.ini` write is satisfied by
  a host-owned file mounted from `.run/` (see `nextcloud-app.container.in`).
  If an image bump makes the entrypoint fail with "Permission denied", the path
  moved — do not reach for `User=root` (it leaves root-owned sub-uid files in the
  volumes).
- Never use `chown`/`find -user` with a literal id. Use `podman unshare id` (what
  the invoking user is *inside* Podman's namespace) or run the helper with
  `--userns=keep-id` so it acts as the user.
- The `html` volume's `data` mount-point directory must be created by us
  (`prepare_html_volume`); if Podman creates it, it is owned by a sub-uid.
- Prove ownership with the audit in `./setup.sh status`, and prove SMB behaviour
  with `tests/smb-live-test.sh` (it has a documented negative control: give
  `admin/files` to a sub-uid and it must fail; `tests/t05-smb.sh` runs both).
- **Cron's `crond` is the one sub-uid process.** Wherever you enumerate processes or
  ownership (docs, comments, tests), name that exception. `RunInit=yes` is what makes
  it stop in ~0.3 s; do not remove it or `User=root`.

### 1. Never hand-edit `config.php`

`/var/www/html/config/config.php` is *generated* by the image from the
`*.config.php` fragments it ships, and re-merged on every write. Those fragments
take precedence over `config.php`.

Consequences:

- To set something the image manages (Redis, APCu, anything env-driven), set the
  **environment variable** (`.env` → `.run/app.env` by `write_env_files`). Do not call `occ`.
- Writing a managed key with `occ config:system:set` leaves a value in
  `config.php` that is silently shadowed at runtime — and that would suddenly
  become live if the env var were ever removed. This is how the earlier
  `memcache.*` duplication bug happened. Do not reintroduce it.
- `occ` is still correct for keys the image does not manage (that is what the
  hook does) and for anything Nextcloud itself owns (app config, users, etc.).

### 2. The hook sets only unmanaged keys

`config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh` runs on every
start. It must:

- stay **idempotent** (`occ config:system:set` is a set, not an append);
- stay **executable** (mode `0755`) — the entrypoint skips non-executable files;
- **exit 0** when `config.php` is missing or the instance is not installed, so a
  broken install does not produce a confusing `occ` error;
- **fail loudly** on a real error while applying settings — a half-configured
  instance is worse than one that refuses to start;
- set **only** keys the image does not already manage.

### 3. All five hook subdirectories must exist

`config/nextcloud-hooks/` is mounted over `/docker-entrypoint-hooks.d`, which
**hides the image's own hook directories**. Ours must therefore provide the
complete set — `pre-installation`, `post-installation`, `before-starting`,
`pre-upgrade`, `post-upgrade` — even if some are empty (`.gitkeep`).

Deleting an "unused empty" one silently disables a hook category. `setup.sh`
preflight refuses to start if any is missing.

### 4. Volume names are load-bearing

`nextcloud-html`, `nextcloud-db`, `nextcloud-redis`, `nextcloud-caddy-data` have fixed
names. (`nextcloud-data` no longer exists: user data is the host directory
`DATA_HOST_PATH`.)
`setup.sh backup`/`restore` mount them **by name**; the Quadlet `Volume=` lines use the same names. Renaming a volume silently
points the helpers at a new, empty volume.

`nextcloud-html` is `/var/www/html`; the data directory is bind-mounted at `/var/www/html/data`.

### 5. `config.php` must be in every backup

`instanceid`, `secret` and `passwordsalt` live **only** in `config.php` —
`instanceid` is *not* in the database on Nextcloud 35. A database-only restore
produces an **orphan instance**: the data directory is named
`appdata_<instanceid>`, the database references the old id, and logins are
refused. `backup` therefore emits `config.tar.gz`, and `restore` puts it back.
Do not "optimise" it away.

### 6. `restore` must install once before overwriting `config/`

Podman copies the image's contents into a named volume **only while the volume
is still empty**. Restoring `config/` into a never-populated `nextcloud-html`
yields a container with no program files. Hence the deliberate order in
`cmd_restore`: validate the archives (`gzip -t` + `tar -t`; a bad backup is refused
before anything is touched) → prompt (shows the backup dir **and** the data dir that
will be emptied) → save the current `.env` as `.env.pre-restore.<timestamp>` and copy
**only** the DB/admin credentials (`DB_NAME`, `DB_USER`, `DB_PASSWORD`,
`DB_ROOT_PASSWORD`, `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`) from
`env.backup` (ports, bind, `DATA_HOST_PATH`, images stay as on this machine) → stop
the stack, remove the containers and the `nextcloud-html`/`-db`/`-redis` volumes
(`nextcloud-caddy-data` is kept) → fix ownership and empty the data directory
(failure is fatal, emptiness is verified) → start everything fresh (throwaway
install) → wait → stop `caddy`+`cron`+`app` → drop/recreate/import the DB → restore
data (as the invoking user, `--no-same-owner`) and `config.php` → start all five
units → scrub the install secrets (see 10) → verify instance id and user count.
The data directory **must be empty** for the throwaway install: the installer
refuses ("Login is invalid because files already exist for this user") otherwise.
`restore` with no argument picks the newest **complete** backup; a failed `backup`
removes its partial directory.

### 7. Never `rm -rf /var/www/html/data` via `--volumes-from`

`/var/www/html/data` is itself a mount point inside the app container, so it
cannot be removed from a container that inherits the mounts — you get
`Resource busy`. Bind-mount `DATA_HOST_PATH` directly at a *different* path (the
helpers mount it at `/target`, as the invoking user via `--userns=keep-id`) and
wipe that.

### 8. Tar format is unified — do not diverge

Both directions use busybox tar in a throwaway `alpine:3` container:

- volume archives are made with `tar -C <parent> <dir>` and restored with
  `--strip-components=1`; helpers run with `--userns=keep-id` so extracted files
  belong to the invoking user (`--no-same-owner`);
- the config archive keeps its `config/` prefix and is restored *without*
  stripping, into the `html` volume.

Breaking either convention silently restores files to the wrong depth.

### 9. `Caddyfile`: no top-level directives, and the cert path must be mounted

- Directives outside a `{ … }` global block or a site block are parsed as a
  **site address**. A flat file starting with `auto_https off` makes Caddy match
  only `Host: auto_https`/`off`, so real requests match no route and get an
  **empty HTTP 200** (the "blank page"). Keep the `{ auto_https off }` global
  block and the `:443 { … }` site block.
- `tls /etc/caddy/tls/site.crt …` only works because the caddy unit mounts `./tls`
  there; `setup.sh ensure_tls` generates it. Do not point `tls` at a path that no
  mount provides.
- Verify structure with `caddy adapt` (see README → *Reverse proxy*) before
  concluding anything about Nextcloud or Apache.
- Nextcloud learns it is behind HTTPS via `TRUSTED_PROXIES` (env, in
  `.run/app.env`, written by `setup.sh`). Do **not** set `overwriteprotocol`: it would break plain HTTP.
  The keys `trustedProxies.*` and `overwrite.protocol` do not exist in Nextcloud;
  the real ones are `trusted_proxies` and `overwriteprotocol`.
- `redir /.well-known/caldav` and `/carddav` stay **relative** 301s to
  `/remote.php/dav/`: Apache's own redirect is absolute and built from its plain-HTTP
  scheme, which downgrades CalDAV/CardDAV clients to `http://`.
- Nextcloud is served at `/`, never under a `/nextcloud` prefix.

### 10. Administrator credentials live in the app environment only until installed

`write_env_files` includes `NEXTCLOUD_ADMIN_USER`/`NEXTCLOUD_ADMIN_PASSWORD` in
`.run/app.env` only while `instance_installed` is false (`config.php` has
`'installed' => true`). `scrub_install_secrets` (called by `up` and `restore`) rewrites
`app.env` without them and restarts `app` once, so `podman inspect nextcloud-app` never
shows the password. Do not put them back, and never print or write a secret value in
docs, tests or logs (use placeholders; the test library redacts known values). The db
root password belongs only in `db.env`. `.run/` is `0700`, its files `0600`.

### 11. `uninstall`, drift and quiesce

- `uninstall` stops the services, removes the containers, the rendered
  `nextcloud*.container|.network` units and `.run/`, and **keeps** volumes, the data
  directory, `.env` and `tls/`. It must stay unable to lose data.
- `up` stores a hash of the rendered units and env files in `.run/.applied`
  (`mark_applied`) and prints `...run ./setup.sh restart to apply it.` when the hash no
  longer matches (`warn_if_drift`); it must not apply changes silently. `restart` applies.
- `backup --quiesce` turns maintenance mode on and **always** off again (EXIT trap,
  also on failure); a failed backup removes its partial directory. **Never archive
  `config.php` after entering maintenance mode**: Nextcloud keeps its maintenance flag
  in `config.php`, so such a backup restores into a stuck maintenance mode. The config
  archive is taken first. `restore` ends by switching maintenance mode off (with a
  warning) if the restored configuration had it on.
- `down` stops the units and, because Quadlet containers run with `--rm`, removes the
  containers (volumes, data and images are kept). `uninstall` also removes the units and
  `.run/` and leaves the Podman network object; `destroy` removes the network.
- A fresh install (no `nextcloud-html` volume) with a non-empty `DATA_HOST_PATH` is
  refused in preflight with a clear message; never loosen that check.

### 12. Developer knobs and sourceability

`NEXTCLOUD_ENV_FILE`, `NEXTCLOUD_RUN_DIR`, `NEXTCLOUD_QUADLET_DIR` and
`NEXTCLOUD_NO_RELOAD` redirect `setup.sh` into throw-away directories (no
`daemon-reload` with the last). `setup.sh` runs `main` only when executed, so tests
`source` it and call functions. Keep both properties: tests depend on them. The
constants are read at source time.

## Conventions to preserve

- **Secrets** come from `openssl rand -hex 24` (hex only — no quoting or
  `pipefail` hazards when injected into `.env`); `od` is the fallback. `ensure_env`
  **never regenerates secrets when `.env` already exists**.
- **Destructive commands ask for typed confirmation** (`destroy` → `DELETE`,
  `restore` → `RESTORE`). Keep it that way. `destroy` removes the containers, the
  four named volumes (html, db, redis, caddy-data) and the network, **verifies** they
  are gone (fails otherwise), never deletes `DATA_HOST_PATH`, and leaves the rendered
  units installed in `~/.config/containers/systemd`.
- **`legacy_cleanup`** (run by `up`/`restart`/`restore`) removes only leftover
  non-Quadlet containers named exactly `nextcloud-db|-redis|-app|-cron|-caddy`
  (`podman rm -f --depend`); volumes and data are untouched.
- **`occ`** allocates stdin/TTY when run interactively (so `user:add` prompts work)
  and runs as the web account from `APP_RUN_USER` (default `www-data`), not a literal.
- **A plain `backup` is not quiesced**: the DB dump is a transaction snapshot and the
  data tar is taken afterwards from the live directory. For exact consistency use
  `./setup.sh backup --quiesce`.
- **Adding a configuration key** means: read it with `env_or`/`env_get`/`env_need`
  (or in the hook), add it to `.env.example` and to the README configuration
  reference. `tests/t11-docs.sh` and `tests/t01-static.sh` fail otherwise.
- **`cmd_help` reads the file's own header comment** via `awk`, not hard-coded
  line numbers. Keep the usage block as the leading comment block.
- **Adding a subcommand** means: implement `cmd_<name>`, add it to the dispatch
  `case`, document it in both the header comment and the README `setup.sh` reference
  table, and add a check for it to a test module.
- Shell style is Bash for `setup.sh` and POSIX `sh` for the hook (the hook runs
  in the container). `bash -n setup.sh` and `sh -n <hook>` before committing.

## Verification before claiming anything works

```bash
bash -n setup.sh
sh -n config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh
./setup.sh up
./setup.sh status                              # units active, ownership ok
tests/run-all.sh --non-destructive             # live suite + evidence package
tests/t11-docs.sh                              # docs match code (read-only, quick)
```

Run the test suite before claiming anything works; read `report.md` in the evidence
directory it prints, not just the exit status. Use the full `tests/run-all.sh` (it
restarts services, destroys and restores the instance, so back up first) when you touch
`restore`, `destroy`, `uninstall`, `backup` or the unit templates. Do not state that
the stack works from reading code. The `restore` path in particular is only meaningful
after a real `destroy` → `backup` → `restore` drill (`tests/t08-backup-restore.sh`),
because several of its bugs (volume-population order, tar depth) are invisible until
the volumes are actually gone.

## Tests are part of every change

- **New behaviour needs a test**: a check in an existing `tests/tNN-*.sh` module or a
  new module (add it to `MODULES` in `tests/run-all.sh`, and to `DESTRUCTIVE` if it
  changes the stack). A bug fix needs a check that fails without the fix. See
  `tests/README.md` for the library API.
- **Tests never hard-code** a uid, gid, path, port, user name, subnet or host name:
  read them from `.env`, `id`, the images or the Podman network. `t01-static` fails if
  one appears. Tests are deterministic (`t_wait`, no bare `sleep`), self-cleaning, and
  carry negative controls.
- **Docs are tested**: change code and docs together. `t11-docs` checks commands,
  config keys, ports, image tags, unit names, repo paths, the TOC and the cron
  exception, and every module must be described in `tests/README.md`.
- Never weaken or delete a check to make a run pass, and never paste a secret into a
  test, doc or log. Figures in docs must be dated or taken from an evidence report.

## Known non-issues — do not "fix" these

- **`backgroundjobs_mode` is app config.** `occ config:system:get
  backgroundjobs_mode` prints nothing and exits 1. That is correct; use
  `occ config:app:get core backgroundjobs_mode` (→ `cron`).
- **`nextcloud-cron` and its stop signal.** Busybox `crond` is PID 1 in its container
  and installs no signal handlers, and the kernel drops signals a PID 1 has no
  handler for — so neither the image's `SIGWINCH` nor `SIGTERM` ever stopped it
  (10 s timeout, `SIGKILL`, exit 137, unit `failed`). The unit therefore uses
  `RunInit=yes` (a tiny init forwards the signal; stop takes ~0.3 s) plus
  `StopSignal=SIGTERM` and `SuccessExitStatus=143`. Keep `User=root` for `crond`:
  non-root `crond` silently never runs jobs (`can't set groups`).
- **`nextcloud-network.service` stays "active"** after it ran (one-shot). If you
  remove the network behind systemd's back, `ensure_network` restarts the unit.
- **`RedisException` lines in `nextcloud.log` are usually historical**, captured
  while Redis/DB were bouncing during maintenance. Compare timestamps before
  reacting.
- **`ls <glob>` inside a container fails** because `ls` does not expand globs.
  Wrap it: `podman exec nextcloud-app sh -c 'ls -d /var/www/html/data/appdata_*'`.

## Residue not managed by this stack

`nextcloud_aio_mastercontainer` (volume), `nextcloud/all-in-one:latest` and
`nextcloud:latest` (images) are leftovers from an abandoned AIO attempt. AIO
hard-requires `/var/run/docker.sock`, which rootless Podman cannot provide, so it
is a dead end — do not retry it, and do not wire it back in. `setup.sh destroy`
does not remove this residue because it is outside this stack; removal
is documented under *Cleanup* in `README.md`.

## Environment observed here

ALT Starterkit 11 (kernel 6.12.61), 8 cores, 62 GB RAM, hostname `nezha`.
Podman 5.7.1 (rootless), Quadlet, `systemd --user` with lingering.
Host tuning (`vm.overcommit_memory=1`, `net.core.rmem_max`) is optional and needs root;
`./setup.sh status` prints the advice, `setup.sh` never applies it. Required secrets live in `.env`
(mode `0600`, git-ignored). `nft` is present but its ruleset is **not readable**
by the host user, so VPN/firewall questions cannot be answered by inspecting
`nft` — use `ip route` / `ip rule` instead.
