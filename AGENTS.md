# AGENTS.md — working in this repository

Agent-facing notes. `README.md` is the human-facing document and is authoritative
on *behaviour*; this file records the constraints that are easy to violate and
hard to notice.

## What this repository is

A private, **LAN-only** Nextcloud instance on **rootless Podman**, with no domain.
HTTPS is provided by a Caddy front end with a **self-signed** certificate. There
is no public exposure and adding one (public DNS, ACME, port forwarding) is out
of scope.

The stack is a compose project (`compose.yaml`) driven by `setup.sh`:

| Service | Image | Notes |
| --- | --- | --- |
| `app` | `nextcloud:35-apache` | plain HTTP, published `${NEXTCLOUD_PORT:-8080} → 80` (`.env` here uses `8280`: `8080`/`8081` belong to code-server / helix-auth) |
| `caddy` | `localhost/helixcode-caddy-brotli:2` | TLS terminator, published `52443 → 443` tcp+udp (HTTP/3); proxies to `app:80` |
| `db` | `mariadb:11` | **not** published to the host |
| `redis` | `redis:7-alpine` | cache + file locking + PHP sessions; **not** published |
| `cron` | same image as `app` | `entrypoint: /cron.sh` |

`app` and `cron` share the image through the `x-nextcloud-image` YAML anchor.
**Edit the anchor, never the two `image:` lines** — that anchor is what stops the
two services from drifting to different versions.

## Hard constraints

### 1. Never hand-edit `config.php`

`/var/www/html/config/config.php` is *generated* by the image from the
`*.config.php` fragments it ships, and re-merged on every write. Those fragments
take precedence over `config.php`.

Consequences:

- To set something the image manages (Redis, APCu, anything env-driven), set the
  **environment variable** in `compose.yaml` / `.env`. Do not call `occ`.
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

`nextcloud-html`, `nextcloud-data`, `nextcloud-db`, `nextcloud-redis` are given
explicit `name:`s so they do not depend on the compose project prefix.
`setup.sh backup`/`restore` mount them **by name**. Renaming a volume silently
points the helpers at a new, empty volume.

`nextcloud-html` is `/var/www/html`; `nextcloud-data` is `/var/www/html/data`.

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
`cmd_restore`: `compose up -d` (throwaway install) → wait → stop `app`+`cron` →
replace DB / data / config → `compose up -d`.

### 7. Never `rm -rf /var/www/html/data` via `--volumes-from`

`/var/www/html/data` is itself a mount point inside the app container, so it
cannot be removed from a container that inherits the mounts — you get
`Resource busy`. Mount `nextcloud-data` directly at a *different* path (which is
what `volume_restore` does) and wipe that.

### 8. Tar format is unified — do not diverge

Both directions use busybox tar in a throwaway `alpine:3` container:

- volume archives are made with `tar -C <parent> <dir>` and restored with
  `--strip-components=1`;
- the config archive keeps its `config/` prefix and is restored *without*
  stripping, into the `html` volume.

Breaking either convention silently restores files to the wrong depth.

### 9. `Caddyfile`: no top-level directives, and the cert path must be mounted

- Directives outside a `{ … }` global block or a site block are parsed as a
  **site address**. A flat file starting with `auto_https off` makes Caddy match
  only `Host: auto_https`/`off`, so real requests match no route and get an
  **empty HTTP 200** (the "blank page"). Keep the `{ auto_https off }` global
  block and the `:443 { … }` site block.
- `tls /etc/caddy/tls/site.crt …` only works because compose mounts `./tls`
  there; `setup.sh ensure_tls` generates it. Do not point `tls` at a path that no
  mount provides.
- Verify structure with `caddy adapt` (see README → *Reverse proxy*) before
  concluding anything about Nextcloud or Apache.
- Nextcloud learns it is behind HTTPS via `TRUSTED_PROXIES` (env, in
  `compose.yaml`). Do **not** set `overwriteprotocol`: it would break plain HTTP.
  The keys `trustedProxies.*` and `overwrite.protocol` do not exist in Nextcloud;
  the real ones are `trusted_proxies` and `overwriteprotocol`.
- Nextcloud is served at `/`, never under a `/nextcloud` prefix.

## Conventions to preserve

- **Secrets** come from `openssl rand -hex 24` (hex only — no quoting or
  `pipefail` hazards when injected into `.env`); `od` is the fallback. `ensure_env`
  **never regenerates secrets when `.env` already exists**.
- **Destructive commands ask for typed confirmation** (`destroy` → `DELETE`,
  `restore` → `RESTORE`). Keep it that way.
- **`cmd_help` reads the file's own header comment** via `awk`, not hard-coded
  line numbers. Keep the usage block as the leading comment block.
- **Adding a subcommand** means: implement `cmd_<name>`, add it to the dispatch
  `case`, and document it in both the header comment and `README.md`.
- Shell style is Bash for `setup.sh` and POSIX `sh` for the hook (the hook runs
  in the container). `bash -n setup.sh` and `sh -n <hook>` before committing.

## Verification before claiming anything works

```bash
bash -n setup.sh
sh -n config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh
./setup.sh up
curl -s http://localhost:8080/status.php     # "installed":true
./setup.sh occ status
```

Do not state that the stack works from reading code. The `restore` path in
particular is only meaningful after a real `destroy` → `backup` → `restore`
drill, because several of its bugs (volume-population order, tar depth) are
invisible until the volumes are actually gone.

## Known non-issues — do not "fix" these

- **`backgroundjobs_mode` is app config.** `occ config:system:get
  backgroundjobs_mode` prints nothing and exits 1. That is correct; use
  `occ config:app:get core backgroundjobs_mode` (→ `cron`).
- **`nextcloud-cron` takes ~10s to stop.** Busybox `crond` ignores `SIGWINCH`, so
  Podman falls back to `SIGKILL`. Cosmetic; the container holds no state.
- **`RedisException` lines in `nextcloud.log` are usually historical**, captured
  while Redis/DB were bouncing during maintenance. Compare timestamps before
  reacting.
- **`ls <glob>` inside a container fails** because `ls` does not expand globs.
  Wrap it: `podman exec nextcloud-app sh -c 'ls -d /var/www/html/data/appdata_*'`.

## Residue not managed by compose

`nextcloud_aio_mastercontainer` (volume), `nextcloud/all-in-one:latest` and
`nextcloud:latest` (images) are leftovers from an abandoned AIO attempt. AIO
hard-requires `/var/run/docker.sock`, which rootless Podman cannot provide, so it
is a dead end — do not retry it, and do not wire it back in. `setup.sh destroy`
does not remove this residue because it is outside the compose project; removal
is documented under *Cleanup* in `README.md`.

## Environment observed here

ALT Starterkit 11 (kernel 6.12.61), 8 cores, 62 GB RAM, hostname `nezha`.
Podman 5.7.1 (rootless), `podman-compose` 1.5.0. Required secrets live in `.env`
(mode `0600`, git-ignored). `nft` is present but its ruleset is **not readable**
by the host user, so VPN/firewall questions cannot be answered by inspecting
`nft` — use `ip route` / `ip rule` instead.
