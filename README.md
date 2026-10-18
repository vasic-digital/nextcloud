# Nextcloud on Podman — private LAN instance, no domain required

A self-contained Nextcloud deployment that runs on **rootless Podman** and is
reachable **only from your local network**. There is no domain, no TLS
certificate, no reverse proxy and no inbound exposure to the internet — the
whole point is a personal cloud on your own LAN.

Everything is driven by two files you can read in a few minutes: `compose.yaml`
(the stack) and `setup.sh` (a wrapper that removes the error-prone manual
steps). Four containers, four volumes, one published port.

```console
$ ./setup.sh
==> Generating .env with fresh secrets
  ok .env (mode 0600)
==> Preflight checks
  ok podman version 5.7.1
  ok rootless podman
  ok host port 8080 available (bind 0.0.0.0)
  ok container hooks present and executable
==> Starting the stack
...
==> Waiting for Nextcloud to finish installing (up to 600s)
  ok web interface is up and reported as installed (after 25s)

  Nextcloud is ready

  On this machine   http://localhost:8080
  From the LAN      http://192.168.1.139:8080
  By host name      http://nezha:8080

  Administrator     admin
  Password          08e0c2ec201431228503af8bbeaf9bd955968a8938730b4f
  Credentials file  /run/media/milosvasic/DATA4TB/Projects/nextcloud/.env
```

---

## Table of contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Accessing the instance](#accessing-the-instance)
- [Repository layout](#repository-layout)
- [Configuration reference (`.env`)](#configuration-reference-env)
- [How the pieces fit together](#how-the-pieces-fit-together)
  - [The four services](#the-four-services)
  - [Volumes: what lives where](#volumes-what-lives-where)
  - [Redis: cache, file locking *and* PHP sessions](#redis-cache-file-locking-and-php-sessions)
  - [`config.php` is generated — do not hand-edit it](#configphp-is-generated--do-not-hand-edit-it)
  - [The container hook](#the-container-hook)
  - [Background jobs](#background-jobs)
- [`setup.sh` reference](#setupsh-reference)
- [Backups](#backups)
- [Restoring a backup](#restoring-a-backup)
- [Upgrading](#upgrading)
- [Troubleshooting](#troubleshooting)
- [Security posture](#security-posture)
- [VPNs and container networking](#vpns-and-container-networking)
- [Cleanup: leftovers from earlier attempts](#cleanup-leftovers-from-earlier-attempts)
- [Uninstall](#uninstall)
- [Design decisions and why](#design-decisions-and-why)
- [Verified state](#verified-state)

---

## What you get

| Component | Image | Purpose |
| --- | --- | --- |
| `app` | `nextcloud:35-apache` | Web UI and the only published port |
| `db` | `mariadb:11` | Metadata database (users, shares, file cache) |
| `redis` | `redis:7-alpine` | Cache, file locking, PHP sessions |
| `cron` | `nextcloud:35-apache` | Runs `cron.php` every 5 minutes |

- **One published port:** `0.0.0.0:8080 → app:80`. The database and Redis are
  reachable *only* on the private bridge network — they are not published to
  the host at all.
- **No domain, no TLS.** Nextcloud is served over plain HTTP. It works from any
  browser on your LAN with no certificate warnings, because nothing is
  pretending to be a public service.
- **Idempotent.** Running `./setup.sh up` twice does not create a second stack,
  and never regenerates secrets that already exist.
- **Backup and restore are first-class**, not a README recipe: `./setup.sh
  backup` and `./setup.sh restore`.

---

## Architecture

```
                        your LAN (192.168.1.0/24)
                                 │
                                 │  http://nezha:8080
                                 ▼
              ┌──────────────────────────────────────┐
              │  host: nezha  (ALT Linux, rootless   │
              │                Podman 5.7.1)         │
              │                                      │
              │   nextcloud-net  (private bridge)    │
              │  ┌────────────────────────────────┐  │
              │  │                                │  │
  8080/tcp ───┼──┤  nextcloud-app   (apache/php)  │  │
  published   │  │      │                         │  │
              │  │      ├── nextcloud-db    3306  │  │  ← not published
              │  │      └── nextcloud-redis 6379  │  │  ← not published
              │  │                                │  │
              │  │  nextcloud-cron  (crond →      │  │
              │  │                   cron.php)    │  │
              │  └────────────────────────────────┘  │
              │                                      │
              │  volumes:                            │
              │    nextcloud-html   → /var/www/html  │
              │    nextcloud-data   → .../html/data  │
              │    nextcloud-db     → /var/lib/mysql │
              │    nextcloud-redis  → /data          │
              └──────────────────────────────────────┘
```

Request path: browser → host port 8080 → `app:80` → PHP reads/writes
`nextcloud-data`, caches and locks in `nextcloud-redis`, and stores metadata in
`nextcloud-db`. The `cron` container shares `nextcloud-html` and
`nextcloud-data` with `app` and runs maintenance independently of web traffic.

---

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Podman ≥ 4.x | Tested on 5.7.1, **rootless**. `podman info --format '{{.Host.Security.Rootless}}'` should print `true`. |
| `podman-compose` | Tested with 1.5.0. `podman compose` (the wrapper) also works if you prefer it. |
| ~5 GB free disk | Images are ~1.9 GB; the rest is for user data and the database. |
| A free TCP port | Default `8080`. `setup.sh` fails early with a clear message if it is taken. |
| `curl` | Optional — `setup.sh` falls back to a Bash `/dev/tcp` probe. |
| `openssl` or `od` | Only used once, to generate the initial secrets. |

No `sudo` is required anywhere. Everything runs as your user.

---

## Quick start

```bash
# 1. Start everything. Creates .env with random secrets on first run,
#    waits until the web UI answers, then prints the URLs and password.
./setup.sh

# 2. Open the URL it printed.
#      http://localhost:8080        (this machine)
#      http://<your-lan-ip>:8080    (any other device on the LAN)

# 3. Log in with the admin credentials it printed.
#    Forgot them? They are in .env:
./setup.sh creds
```

That is the whole installation. The first start takes roughly 25 seconds
(Nextcloud's own installer runs, the database schema is created, the hook
applies the extra configuration). Subsequent starts take a few seconds.

---

## Accessing the instance

Three equivalent URLs, chosen by where you are:

| Where you are | URL |
| --- | --- |
| On the server itself | `http://localhost:8080` |
| Any other device on the LAN | `http://192.168.1.139:8080` |
| By host name (with local DNS / mDNS) | `http://nezha:8080` |

The LAN address is detected at setup time and written into
`NEXTCLOUD_TRUSTED_DOMAINS`. **If the machine's LAN IP changes** (new DHCP
lease, different network, moving to Wi-Fi), Nextcloud will start answering with
`Access through untrusted domain`. Fix it by adding the new address:

```bash
# edit .env, then
./setup.sh restart
```

### Desktop and mobile clients

Point the official Nextcloud clients at the same URL, e.g.
`http://192.168.1.139:8080`. They work over plain HTTP on a LAN. If you want
them to trust the server without prompting, use the "self-signed certificate"
setting in the client — but note there is no certificate here at all, because
there is no TLS. Clients that mandate HTTPS will need a reverse proxy in front
(see [Security posture](#security-posture)).

---

## Repository layout

```
.
├── compose.yaml                     # the stack: db, redis, app, cron
├── setup.sh                         # launcher + backup + restore + diagnostics
├── .env.example                     # documented template, safe to commit
├── .env                             # generated; secrets; mode 0600; git-ignored
├── .gitignore
├── README.md
├── AGENTS.md                        # notes for AI agents working in this repo
├── backups/                         # git-ignored
│   └── 20261018-211951/
│       ├── database.sql.gz          # consistent dump (--single-transaction)
│       ├── data.tar.gz              # user files
│       ├── config.tar.gz            # config/ — holds config.php + instanceid
│       ├── env.backup               # the .env that matches this dump
│       └── compose.yaml.backup
└── config/
    └── nextcloud-hooks/
        ├── pre-installation/
        ├── post-installation/
        ├── before-starting/
        │   └── 10-nextcloud-tuning.sh   # idempotent occ settings, every start
        ├── pre-upgrade/
        └── post-upgrade/
```

The `config/nextcloud-hooks` tree is mounted read-only at
`/docker-entrypoint-hooks.d` inside the app container. **All five subdirectories
must exist** — mounting over that path hides the image's own hook folders, so
ours has to provide the complete set. `setup.sh` refuses to start if any is
missing.

---

## Configuration reference (`.env`)

`.env` is generated from `.env.example` on first run, filled with random
secrets and detected local values, and given mode `0600`. It is git-ignored.
Edit it freely and run `./setup.sh restart` to apply changes.

### Network

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXTCLOUD_BIND` | `0.0.0.0` | Host address to bind. `0.0.0.0` = whole LAN, `127.0.0.1` = this machine only, or a specific interface IP. |
| `NEXTCLOUD_PORT` | `8080` | Host-side port. The container always serves 80 internally. |
| `NEXTCLOUD_TRUSTED_DOMAINS` | auto-detected | Space-separated host names/IPs Nextcloud will answer for. Anything else gets *Access through untrusted domain*. |
| `NEXTCLOUD_OVERWRITE_CLI_URL` | `http://<host>:8080` | Base URL for links generated outside a web request (e-mail, `occ` output, background jobs). |

### Database

| Variable | Default | Meaning |
| --- | --- | --- |
| `DB_NAME` | `nextcloud` | Database name. |
| `DB_USER` | `nextcloud` | Database user. |
| `DB_PASSWORD` | generated | Database password for `DB_USER`. |
| `DB_ROOT_PASSWORD` | generated | MariaDB root password. |
| `DB_INNODB_BUFFER_POOL` | `512M` | InnoDB buffer pool. Rule of thumb: ~25 % of the RAM you are willing to give MariaDB. |

### First-run administrator

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXTCLOUD_ADMIN_USER` | `admin` | Created **only when the data volume is still empty**. |
| `NEXTCLOUD_ADMIN_PASSWORD` | generated | Same — first start only. Change it later with `./setup.sh occ user:resetpassword admin`. |
| `DEFAULT_PHONE_REGION` | *(empty)* | ISO 3166-1 alpha-2 code (e.g. `RS`) used to interpret phone numbers typed without a country prefix. Setting it stops Nextcloud warning on every profile save. |

### PHP and Apache

| Variable | Default | Meaning |
| --- | --- | --- |
| `PHP_MEMORY_LIMIT` | `512M` | PHP `memory_limit`. |
| `PHP_UPLOAD_LIMIT` | `16G` | PHP `upload_max_filesize` / `post_max_size`. |
| `APACHE_BODY_LIMIT` | `0` | `0` disables Apache's `LimitRequestBody`, so large uploads are never truncated before PHP sees them. Set a byte value if you would rather have Apache reject oversized uploads outright. |

### Misc

| Variable | Default | Meaning |
| --- | --- | --- |
| `TZ` | auto-detected | Timezone for all containers. Drives the maintenance window. |

> **Changing the administrator password in `.env` after the first start has no
> effect.** It is read once, by the installer, while the data volume is empty.
> Use `./setup.sh occ user:resetpassword admin` instead.

---

## How the pieces fit together

### The four services

**`app`** — the only service with a `ports:` mapping, and therefore the only
one reachable from outside the Podman network. It `depends_on` `db` and `redis`
with `condition: service_healthy`, so compose will not even start it until
MariaDB reports `--innodb_initialized` and Redis answers `PING`. This is why the
stack comes up cleanly instead of racing its own database.

**`db`** — MariaDB 11 with the three settings Nextcloud's own documentation
recommends: `--transaction-isolation=READ-COMMITTED`, `--binlog-format=ROW`, and
an InnoDB buffer pool sized from `.env`. `--skip-name-resolve` is added because
reverse DNS on a private bridge is pure latency with no benefit.
`MARIADB_AUTO_UPGRADE=1` lets the image apply its own minor-version schema
upgrades on start, so pulling a newer `mariadb:11` does not strand you.

**`redis`** — see below.

**`cron`** — reuses the exact same image via the `x-nextcloud-image` YAML anchor,
so `app` and `cron` can never drift apart in version. It overrides
`entrypoint: /cron.sh`, which the image ships: a busybox `crond` reading the
bundled `www-data` crontab, running `php -f /var/www/html/cron.php` every five
minutes.

### Volumes: what lives where

| Volume | Mount | Contents | Replaceable? |
| --- | --- | --- | --- |
| `nextcloud-html` | `/var/www/html` | Program files, `config/config.php`, apps, themes | Yes — re-populated from the image |
| `nextcloud-data` | `/var/www/html/data` | **User files**, `appdata_*`, `nextcloud.log` | **No — back this up** |
| `nextcloud-db` | `/var/lib/mysql` | Metadata (users, shares, file cache) | No |
| `nextcloud-redis` | `/data` | Cache, locks, PHP sessions | Yes — disposable by design |

The volumes are deliberately given **explicit names** (`html: name:
nextcloud-html`) rather than relying on compose's project-prefix convention. That
means their names are stable no matter what the project is called, which matters
because `setup.sh backup`/`restore` mount them by name.

`/var/www/html/data` is a **separate volume on purpose**. Backups can then treat
irreplaceable user files independently from rebuildable code, and you can grow
or move the data volume without touching the program files. This is safe because
`data/` is listed in the image's `/upgrade.exclude`, so image upgrades do not
clobber it.

> ⚠️ Because `/var/www/html/data` is itself a mount point, `rm -rf` on it from a
> container using `--volumes-from` fails with `Resource busy`. `setup.sh`
> therefore mounts `nextcloud-data` directly when restoring. See
> [Troubleshooting](#troubleshooting).

### Redis: cache, file locking *and* PHP sessions

Setting `REDIS_HOST` in `compose.yaml` is doing more than it looks like:

1. The image ships `redis.config.php`, which fills in
   `memcache.distributed`, `memcache.locking` and the whole `redis{host,port,…}`
   block.
2. The entrypoint additionally configures Redis as the **PHP session handler**,
   including session locking.
3. `apcu.config.php` sets `memcache.local` to APCu (in-process, always fastest).

The result, verified at runtime by resolving Nextcloud's own
`ICacheFactory`:

```
local       = OC\Memcache\APCu
distributed = OC\Memcache\Redis
locking     = OC\Memcache\Redis
session     = redis  (save_path = tcp://redis:6379)
```

Redis is configured with `--save 60 1` and no AOF: the cache is disposable, so
losing it on an unclean shutdown costs a cold cache, not data. If Redis is
down, Nextcloud degrades rather than corrupts, because the *locking* came along
with the cache.

### `config.php` is generated — do not hand-edit it

This is the single most important thing to understand about the image.
`/var/www/html/config/config.php` is **rendered** from the `*.config.php`
fragments shipped in the image (`apcu.config.php`, `redis.config.php`,
`upgrade-disable-web.config.php`, …) and any fragments you drop into the mounted
config directory. It is re-merged on every write.

The fragments **take precedence** over `config.php`. So writing a value with
`occ config:system:set` that the image also manages does not override anything —
it leaves a shadowed, misleading value in `config.php` that would suddenly
become live if the environment variable were ever removed. That is why:

- cache / locking / Redis are configured by **setting `REDIS_HOST`**, not by
  `occ`, and
- the hook below deliberately sets only keys the image does not manage.

If you want to add a setting permanently, do it in `config.php` **via `occ`**
(so the image re-renders correctly) or in `.env` (if the image has a fragment
for it). Never open `config.php` in an editor.

### The container hook

`config/nextcloud-hooks/before-starting/10-nextcloud-tuning.sh` runs on **every**
container start, after the entrypoint has finished installing or upgrading. It
is idempotent (`occ config:system:set` is a set — running it a hundred times
equals running it once) and it sets only what the image does not already handle:

| Setting | Why |
| --- | --- |
| `background:cron` | Tell Nextcloud to stop firing background jobs during page loads, since the `cron` service does that properly. (Stored as app config `core/backgroundjobs_mode`.) |
| `maintenance_window_start=1` | Run heavy maintenance at 01:00 instead of on the hour, so nightly jobs do not compete with evening uploads. |
| `overwrite.cli.url` | Correct base URL in links generated outside a web request. Set only if `NEXTCLOUD_OVERWRITE_CLI_URL` is non-empty. |
| `default_phone_region` | Only if `DEFAULT_PHONE_REGION` is non-empty. |
| `lost_password_link=disabled` | There is no mail server, so the "forgot password" link would send mail into the void. Recover the password from `.env` instead. |

It **exits 0** when `config.php` does not exist or the instance is not installed,
so it cannot produce a confusing `occ` error on a broken install. But any
*failure* while applying settings aborts container startup on purpose — a
half-configured instance is worse than one that refuses to start.

### Background jobs

Nextcloud's default is `ajax` mode: background jobs fire opportunistically while
somebody happens to load a page. That means previews, trash cleanup, federation
sync and mail notifications stall whenever nobody is logged in.

This stack runs a dedicated `cron` container instead, and the hook switches the
instance to `cron` mode. It logs `crond (busybox 1.37.0) started, log level 8`
and then runs `cron.php` every five minutes. Confirm the mode with:

```bash
./setup.sh occ config:app:get core backgroundjobs_mode    # → cron
```

> Note the setting lives in **app config**, not system config. `occ
> config:system:get backgroundjobs_mode` will print nothing and exit 1. That is
> expected, not a bug.

---

## `setup.sh` reference

```
./setup.sh [command]
```

| Command | What it does |
| --- | --- |
| `up` *(default)* | Create `.env` if missing, run preflight checks, start the stack, wait for the web UI to report itself installed, print access URLs. |
| `down` | Stop and remove the containers. **Volumes are kept.** |
| `restart` | `down` + `up`. Use after editing `.env` or `compose.yaml`. |
| `status` | Container state, published ports, volumes, disk usage per volume, and a live health probe. |
| `logs [svc]` | Follow logs — all services, or one of `app`, `db`, `redis`, `cron`. |
| `occ ...` | Run an `occ` command inside the running app container as `www-data`. |
| `creds` | Print the generated administrator user and password. |
| `backup` | Write a consistent database dump plus data and config archives. |
| `restore [d]` | Replace the current instance with a backup (newest by default, or a timestamp / directory). Asks for confirmation. |
| `destroy` | Remove containers, network **and every volume**. Asks for confirmation. |
| `help` | Print the usage block. |

**Preflight checks** run before anything is created and will stop you early if
something is wrong:

- Podman present; reports whether it is rootless (warns if rootful).
- `NEXTCLOUD_PORT` is a valid TCP port.
- The port is not already held by another process — unless it is held by *our*
  stack, in which case that is fine.
- All five hook subdirectories exist and the tuning script is executable.
- `backups/` exists.

**`up` also fails fast rather than waiting out its timeout**: if the app
container exits during startup, it prints the last 30 log lines and aborts. On a
clean timeout it prints 40 lines. You never get "it hung and I don't know why".

`logo`/`probe_status` detail: the health probe asks
`http://127.0.0.1:<port>/status.php` and requires `"installed": true`, not
merely a TCP connection. A half-installed instance is therefore not reported as
ready. It uses `curl` when available and a Bash `/dev/tcp` request otherwise.

### Everyday recipes

```bash
# Create a user
./setup.sh occ user:add alice

# Reset the administrator password
./setup.sh occ user:resetpassword admin

# Validate the instance
./setup.sh occ status

# Re-scan files after copying something into the data volume by hand
./setup.sh occ files:scan --all

# Check the throughput of the Redis cache
podman exec nextcloud-redis redis-cli info stats | head

# Set the instance to maintenance mode before fiddling with the database
./setup.sh occ maintenance:mode --on
./setup.sh occ maintenance:mode --off
```

---

## Backups

```bash
./setup.sh backup
```

Writes `backups/<YYYYmmdd-HHMMSS>/` containing:

| File | What it is | Why it is needed |
| --- | --- | --- |
| `database.sql.gz` | `mariadb-dump --single-transaction --quick --routines --events` | Metadata. `--single-transaction` gives a consistent snapshot **without locking tables**, so a running instance keeps serving requests during the dump. |
| `data.tar.gz` | The whole `nextcloud-data` volume | Irreplaceable user files. |
| `config.tar.gz` | `config/` from the `html` volume | **Holds `config.php`.** See below. |
| `env.backup` | A copy of `.env`, mode `0600` | The dump's tables belong to these credentials. |
| `compose.yaml.backup` | A copy of `compose.yaml` | So you know what generated the data. |

### Why `config.php` is mandatory, not optional

`config.php` holds `instanceid`, `secret` and `passwordsalt`. **`instanceid` is
not stored in the database** on Nextcloud 35 — `occ config:system:get instanceid`
reads `config.php` alone, and a fresh install generates a *different* one.

So a database-only restore produces an **orphan instance**: the data directory is
named `appdata_<instanceid>`, the database references the old instance id, and
the new instance refuses to let anyone log in. This is why the backup set
includes `config.tar.gz` and why `restore` puts it back.

### Taking a backup safely

The dump is transaction-consistent, so it is fine to run on a live instance. For
a perfectly still snapshot of the user data too, put the instance into
maintenance mode first:

```bash
./setup.sh occ maintenance:mode --on
./setup.sh backup
./setup.sh occ maintenance:mode --off
```

`backups/` is git-ignored — it contains user data and secrets, so never commit
it. Copy it somewhere else on a schedule; `setup.sh` does not do that for you.

---

## Restoring a backup

```bash
# Restore the newest backup
./setup.sh restore

# Restore a specific one (a timestamp as printed by `backup`…)
./setup.sh restore 20261018-211951

# …or a path to a backup directory
./setup.sh restore /mnt/usb/nextcloud-backup/20261018-211951
```

It prints exactly what it is about to overwrite and requires you to type
`RESTORE` before doing anything. This is a **destructive, in-place** operation:
the current files, database and `config.php` are replaced.

### What it actually does, and why in that order

1. **Restores `.env` from the backup.** The dump's tables belong to those
   credentials, so restoring one without the other yields an instance that
   cannot reach its own database.
2. **Creates volumes and containers from scratch** (`compose up -d`).
3. **Waits for the database, then for the web UI.** On a fresh volume this runs
   the image's own installer once and produces a *throwaway* instance.
4. **Stops `app` and `cron`** so nothing is writing while data is swapped. `db`
   and `redis` stay up.
5. **Drops and recreates the database**, then imports `database.sql.gz`.
6. **Wipes and restores `nextcloud-data`** from `data.tar.gz`.
7. **Restores `config/`** into the `html` volume from `config.tar.gz`.
8. **Starts `app` and `cron` again** and waits for the web UI.
9. **Verifies** by printing the restored `instanceid` and the number of user
   accounts — a quick sanity check that you got *your* instance back, not a
   blank one.

Step 3 looks wasteful, and it is deliberate: **Podman only copies the image's
contents into a named volume while that volume is still empty.** Restoring
`config/` into a never-populated `html` volume would give you a container with no
program files. So the volume has to be populated first, and then overwritten.

Ownership of the restored files is preserved as `33:33` (`www-data`), because the
helper container runs as root, so no `chown` pass is needed.

### Verifying a restore

```bash
curl -s http://localhost:8080/status.php    # → "installed":true, "maintenance":false
./setup.sh occ status
./setup.sh occ user:list
./setup.sh occ files:scan --all             # → 0 errors
```

The `instanceid` reported by `restore` should match the one from the backup, and
`/var/www/html/data/` should contain `appdata_<that same id>`.

---

## Upgrading

The image is **pinned**: `app` and `cron` both use `docker.io/library/nextcloud:35-apache`
via the `x-nextcloud-image` anchor. Nothing upgrades unless you say so, and the
two services can never drift apart.

To move to a new major version:

```bash
./setup.sh backup                  # non-negotiable
# edit the anchor in compose.yaml, e.g. nextcloud:36-apache
./setup.sh occ maintenance:mode --on
./setup.sh restart                 # the entrypoint runs the upgrade
./setup.sh occ maintenance:mode --off
./setup.sh occ status              # check needsDbUpgrade / version
```

Notes:

- The image performs the upgrade itself on start. `upgrade.disable-web` is set by
  the image's own fragment, so you cannot accidentally trigger an upgrade by
  clicking through the web UI.
- MariaDB pulls are safe too: `MARIADB_AUTO_UPGRADE=1`.
- Always read the upstream release notes for the target major version — some
  releases drop support for older PHP extensions or database versions.
- Wait for the maintenance window rather than fighting it: it is set to 01:00
  local time.

---

## Troubleshooting

### "Access through untrusted domain"

You reached Nextcloud by a name or IP that is not in
`NEXTCLOUD_TRUSTED_DOMAINS`. This happens most often after the LAN IP changes.

```bash
./setup.sh occ config:system:get trusted_domains   # see what is allowed
# add the new host/IP to NEXTCLOUD_TRUSTED_DOMAINS in .env, then:
./setup.sh restart
```

### Port 8080 is already in use

`setup.sh` detects this during preflight and tells you which process holds it.
Either free the port or pick another:

```bash
# edit NEXTCLOUD_PORT in .env, then
./setup.sh restart
```

(Avoid `8081` on this machine — it is occupied.)

### `down` or `destroy` pauses for ~10 seconds

Harmless. `nextcloud-cron` runs busybox `crond`, which ignores `SIGWINCH`, so
Podman logs:

```
StopSignal SIGWINCH failed to stop container nextcloud-cron in 10 seconds,
resorting to SIGKILL
```

Nothing is lost — the cron container holds no state — but the stop takes ten
seconds. It is cosmetic.

### `rm: can't remove '/var/www/html/data': Resource busy`

You are trying to wipe the data directory from a container started with
`--volumes-from`. `/var/www/html/data` is itself a mount point inside that
container, so the mount shadows the directory and it cannot be removed. Mount the
volume directly instead:

```bash
podman run --rm -v nextcloud-data:/mnt docker.io/library/alpine:3 \
    sh -c 'rm -rf /mnt/* /mnt/.[!.]*'
```

`setup.sh restore` already does this correctly.

### Redis errors in `nextcloud.log`

Entries like `RedisException: Redis server went away` are almost always
**historical** — captured while Redis or the database was being restarted during
maintenance or a restore. Check the timestamp before reacting, and compare it
with the current time in UTC:

```bash
date -u '+%Y-%m-%dT%H:%M:%S'          # now, for comparison
podman exec nextcloud-app tail -3 /var/www/html/data/nextcloud.log
podman exec nextcloud-redis redis-cli ping    # → PONG
```

If the timestamps are old and `PING` answers, there is nothing wrong.

### Files exist on disk but not in the web UI

The file cache is out of sync. Rescan:

```bash
./setup.sh occ files:scan --all
```

### The instance reports `"installed": false` after a restore

The data volume was restored but `config.php` was not, producing an orphan
instance. Restore a set that includes `config.tar.gz` — see
[why `config.php` is mandatory](#why-configphp-is-mandatory-not-optional).

### `ls` on a glob inside a container says "No such file or directory"

`ls` does not expand globs — the shell does. Wrap it:

```bash
podman exec nextcloud-app sh -c 'ls -d /var/www/html/data/appdata_*'
```

### Where do I look for errors?

```bash
./setup.sh logs              # all services
./setup.sh logs app          # just the web front end
podman logs --tail 100 nextcloud-db
tail -f data/nextcloud.log   # inside the container: /var/www/html/data/nextcloud.log
```

---

## Security posture

This deployment is deliberately **not** exposed to the internet. Being clear
about the boundaries matters more than adding complexity:

**What is exposed**

- `0.0.0.0:8080` — the Nextcloud web UI, reachable from anything that can route
  to this host on port 8080. On a typical home LAN that is the LAN only, because
  the router does not forward inbound port 8080.
- Nothing else. `nextcloud-db:3306` and `nextcloud-redis:6379` are *exposed
  inside the container* but **not published to the host** — the `podman ps`
  output shows plain `3306/tcp` with no host mapping. They are reachable only on
  the private `nextcloud-net` bridge.

**What is not**

- No public DNS record, no port forwarding, no reverse proxy, no TLS.
- No `/var/run/docker.sock` mount. (This is why the `all-in-one` image was
  abandoned — see [Cleanup](#cleanup-leftovers-from-earlier-attempts).)
- No rootful daemon: Podman runs rootless as your user.

**Honest limitations — read these**

1. **There is no TLS, so credentials travel in cleartext.** The login POST and
   the session cookie are unprotected on the wire. On a wired home LAN this is
   the same trust model as the rest of your LAN traffic. On a shared, untrusted
   or public Wi-Fi it is not adequate.
2. **There is no host firewall on this machine** — `firewalld` and `ufw` are not
   installed. The only thing keeping the instance private is the bind address
   plus whatever your router does with inbound connections. Again: fine on a
   home LAN, not a substitute for a firewall.
3. **Secrets live in `.env`** at mode `0600`. Anyone who can read your user's
   files has your administrator password and both database passwords. The
   `lost_password_link` is disabled precisely because there is no mail server to
   recover an account through.
4. **The `admin` password is printed by `up`** and stored in `.env` and in every
   `backups/*/env.backup`. Treat backups as sensitive.

**If you want to go further**, in ascending order of effort:

- Add a firewall rule restricting port 8080 to your LAN subnet.
- Put a TLS-terminating reverse proxy (Caddy, nginx) in front and restrict the
  app to `127.0.0.1` via `NEXTCLOUD_BIND`, so only the proxy is reachable.
- Then, and only then, consider exposing it beyond the LAN — at which point you
  should also review Nextcloud's hardening guide.

---

## VPNs and container networking

**Short answer: a VPN breaks nothing here, as long as it is not your default
route.** On this machine the VPN is present but not in the path:

```console
$ ip route show default
default via 192.168.1.1 dev enp0s20f0u3        # real LAN default route

$ ip addr show ppp0
ppp0: <POINTOPOINT,...> ... inet 10.1.106.107 peer 10.1.106.254/32
```

`ppp0` exists (a point-to-point VPN tunnel) but the **default route still goes
out over the physical LAN interface**. Consequences:

- **LAN access works normally.** Both the host and the containers reach
  `192.168.1.0/24` over `enp0s20f0u3`, so `http://192.168.1.139:8080` is
  reachable from your phone, laptop, etc. Container traffic to the LAN is
  masqueraded by Podman's `pasta` networking and appears to come from the host.
- **Container internet access works normally.** Outbound traffic follows the
  default route, so app store downloads and update checks succeed.
- **Redis/DB are unaffected** — they never leave the private bridge.

**The case that does break things** is a VPN configured as a full-tunnel default
route. Then *all* outbound container traffic — including replies to LAN clients
in some kill-switch configurations — can be pulled into the tunnel, and you get
timeouts that look like a broken Nextcloud. Diagnose it like this:

```bash
ip route show default                  # is the VPN the default route?
ip rule show                           # policy rules can bypass the routing table
podman exec nextcloud-app \
    sh -c 'wget -qO- -T5 https://example.com >/dev/null && echo egress OK'
```

If the VPN *is* the default route, split-tunnel it — exclude `192.168.1.0/24`
and, if the VPN software is strict, the Podman bridge subnet as well. Note that
**`nft` rules are not readable by the host user** here (no `CAP_NET_ADMIN`), so
you cannot inspect the VPN's firewall from your account; use `ip route`/`ip rule`
and the egress test above instead.

Finally, one LAN-specific caveat unrelated to routing: if you join a *different*
network, this host's LAN IP changes and Nextcloud will start answering with
`Access through untrusted domain`. Add the new address to
`NEXTCLOUD_TRUSTED_DOMAINS` and restart.

---

## Cleanup: leftovers from earlier attempts

This repository started as an `all-in-one` (AIO) deployment. That image is a
non-starter under rootless Podman: it hard-requires `/var/run/docker.sock` and
aborts with *"Docker socket is not available. Cannot continue."* The socket
cannot be mounted usefully as a non-root user. It was abandoned in favour of the
plain `nextcloud:35-apache` + MariaDB + Redis composition you see now.

The failed attempt left residue that `./setup.sh destroy` does **not** manage,
because it is not part of the compose project:

```console
$ podman volume ls | grep -i nextcloud
nextcloud_aio_mastercontainer     # ← stale, from the AIO attempt
nextcloud-data                    # ← ours
nextcloud-html                    # ← ours
nextcloud-db                      # ← ours
nextcloud-redis                   # ← ours

$ podman images | grep -E 'all-in-one|nextcloud:latest'
docker.io/nextcloud/all-in-one:latest        241 MB   # ← unused
docker.io/library/nextcloud:latest           1.52 GB   # ← unused
```

Remove the residue once you are satisfied you do not need it (this deletes the
stale AIO volume's contents — nothing this README depends on):

```bash
podman volume rm nextcloud_aio_mastercontainer
podman rmi docker.io/nextcloud/all-in-one:latest docker.io/library/nextcloud:latest
```

---

## Uninstall

```bash
# Stop everything but keep all data and volumes
./setup.sh down

# Take a final backup, then remove containers, network and ALL volumes
./setup.sh backup
./setup.sh destroy        # asks you to type DELETE

# Optionally remove the images too
podman rmi docker.io/library/nextcloud:35-apache \
           docker.io/library/mariadb:11 \
           docker.io/library/redis:7-alpine \
           docker.io/library/alpine:3
```

`destroy` is guarded by a typed confirmation and is irreversible. Everything —
user files, database and `config.php` — is gone afterwards. `backups/` on the
host is **not** touched, which is exactly why `config.tar.gz` is in it.

---

## Design decisions and why

| Decision | Rationale |
| --- | --- |
| Plain `nextcloud:35-apache`, not `all-in-one` | AIO requires the Docker socket, which rootless Podman cannot provide. |
| `db` + `redis` + `app` + `cron` | The composition Nextcloud itself documents for a small instance: MariaDB for metadata, Redis for cache/locking/sessions, a dedicated cron container. |
| `0.0.0.0:8080 → 80` | LAN-accessible by choice. The container serves plain HTTP on **80**; 8080 is only the host side. Getting this backwards was the original cause of "the connection is refused". |
| Redis configured by `REDIS_HOST`, not `occ` | The image's own fragments take precedence over `config.php`; setting it twice would leave a misleading shadowed value behind. |
| Hook sets only unmanaged keys | Same reason — everything the image manages is set through the environment. |
| Separate `data` volume | Irreplaceable user files are backed up independently from rebuildable program code. Safe because `/data/` is in `/upgrade.exclude`. |
| Explicit volume names | `backup`/`restore` mount volumes by name, so the names must not depend on a compose project prefix. |
| Pinned image via YAML anchor | `app` and `cron` cannot silently drift to different versions, and nothing upgrades without you asking. |
| `backup` includes `config.tar.gz` | `instanceid` lives only in `config.php`; a DB-only restore is an orphan instance that refuses logins. |
| `restore` is a subcommand, not a README recipe | A manual recipe drifts from reality; a subcommand is testable and was tested. |
| `restore` installs once, then overwrites | Podman populates a named volume from the image only while it is empty. |
| `--single-transaction` dump | Consistent snapshot without locking tables, so backups do not need downtime. |
| Hex secrets from `openssl rand -hex 24` | No quoting or `pipefail` hazards when injected into `.env`; `od` fallback if `openssl` is absent. |
| `help` reads its own header comment | Never prints stale text after the usage block is edited. |
| `destroy` requires typing `DELETE` once | Destructive and irreversible; the confirmation exists for exactly one reason. |

---

## Verified state

This stack was exercised end-to-end rather than assumed to work. As of the last
run:

- **Stack** — all four containers healthy; `nextcloud-app` publishing
  `0.0.0.0:8080->80/tcp`.
- **Web** — `http://localhost:8080/status.php` →
  `{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2"}`
  and the LAN address answers `200`.
- **Runtime caching** — resolved through Nextcloud's own `ICacheFactory`:
  local `APCu`, distributed and locking `Redis`, PHP session handler `redis`,
  with live `PHPREDIS_SESSION:*` keys present in Redis.
- **Hook** — `==> nextcloud-tuning: configuration applied` on every start;
  `maintenance_window_start=1` and `lost_password_link=disabled` present.
- **Background jobs** — `backgroundjobs_mode = cron`, `nextcloud-cron` logging
  `crond (busybox 1.37.0) started`.
- **Database** — healthcheck passing, 138 tables.
- **Backup** — produced `database.sql.gz` (240 KB), `data.tar.gz` (61 MB),
  `config.tar.gz` (36 KB), `env.backup`, `compose.yaml.backup`.
- **Destroy** — `echo DELETE | ./setup.sh destroy` removed all four containers,
  all four volumes and `nextcloud-net`.
- **Restore** — from a completely destroyed state,
  `./setup.sh restore <timestamp>` came back up with the **same instance id**
  (`ocvhsvisemzq`), the `admin` account, `background:cron` applied, and
  `files:scan --all` reporting **5 folders / 64 files / 0 errors**. The data
  directory contains `appdata_ocvhsvisemzq`, matching the restored id.

Versions in this run: Nextcloud 35.0.2.2 (PHP 8.5.11), MariaDB 11.8.9,
Redis 7.4.9, Podman 5.7.1 (rootless), `podman-compose` 1.5.0, on ALT Starterkit
11 (kernel 6.12.61).
