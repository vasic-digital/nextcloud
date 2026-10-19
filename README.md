# Nextcloud on Podman — private LAN instance, no domain required

A self-contained Nextcloud deployment that runs on **rootless Podman** and is
reachable **only from your local network**. There is no domain and no inbound
exposure to the internet — the whole point is a personal cloud on your own LAN.
It is served over plain HTTP on `:8080` and over HTTPS (self-signed, HTTP/3
capable) on `:52443` through a Caddy front end.

Everything is driven by `setup.sh` (a wrapper that removes the error-prone
manual steps) and the unit templates in `systemd/`. Five services — database,
Redis, Nextcloud, cron and a Caddy HTTPS front end — each a **`systemctl --user`
service** (Podman Quadlet) that runs **as your own user**, so every file the
stack writes belongs to you and can be shared over SMB.

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
  Password          <generated-password>
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
  - [The five services](#the-five-services)
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
- [Reverse proxy (Caddy)](#reverse-proxy-caddy)
- [Running under systemd (`--user`)](#running-under-systemd---user)
- [File ownership and SMB access](#file-ownership-and-smb-access)
- [Testing](#testing)
- [Verified state](#verified-state)

---

## What you get

| Component | Image | Purpose |
| --- | --- | --- |
| `app` | `nextcloud:35-apache` | Plain-HTTP web UI (published port 8080) |
| `caddy` | `localhost/nextcloud-caddy-brotli:2` (built from `docker/caddy`) | HTTPS / HTTP/3 front end (published port 52443) |
| `db` | `mariadb:11` | Metadata database (users, shares, file cache) |
| `redis` | `redis:7-alpine` | Cache, file locking, PHP sessions |
| `cron` | `nextcloud:35-apache` | Runs `cron.php` every 5 minutes |

- **Two published ports:** `0.0.0.0:8080 → app:80` (plain HTTP) and
  `0.0.0.0:52443 → caddy:443` (HTTPS, TCP+UDP for HTTP/3). The database and
  Redis are reachable *only* on the private bridge network — they are not
  published to the host at all. Ports and bind address: `NEXTCLOUD_PORT`,
  `NEXTCLOUD_HTTPS_PORT`, `NEXTCLOUD_BIND` in `.env` (`NEXTCLOUD_BIND` applies to
  **both** ports; there is no HTTP-only bind).
- **No domain.** HTTPS uses a self-signed certificate that `./setup.sh`
  generates into `tls/` (SANs: `localhost`, `127.0.0.1`, the host name,
  `<host>.local`, the LAN IP and everything in `NEXTCLOUD_TRUSTED_DOMAINS`) and
  regenerates when a name or the LAN IP changes. Browsers warn once; import
  `tls/site.crt` as a trusted certificate to silence it. Plain HTTP on `:8080`
  keeps working.
- **Idempotent.** Running `./setup.sh up` twice does not create a second stack,
  and never regenerates secrets that already exist.
- **Backup and restore are first-class**, not a README recipe: `./setup.sh
  backup` and `./setup.sh restore`.

---

## Architecture

```
                        your LAN (192.168.1.0/24)
                                 │
                 http://host:8080│        https://host:52443
                                 ▼
              ┌──────────────────────────────────────┐
              │  host  (rootless Podman, Quadlet /   │
              │         systemctl --user)            │
              │                                      │
              │   nextcloud-net  (private bridge)    │
              │  ┌────────────────────────────────┐  │
  52443/tcp+  │  │                                │  │
  udp ────────┼──┤  nextcloud-caddy (TLS, HTTP/3) │  │
              │  │      │ proxies to app:80       │  │
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
              │    nextcloud-html       /var/www/html│
              │    nextcloud-db         /var/lib/mysql│
              │    nextcloud-redis      /data        │
              │    nextcloud-caddy-data /data (caddy)│
              │  bind mount:                         │
              │    DATA_HOST_PATH → .../html/data    │
              └──────────────────────────────────────┘
```

Request path: browser → host port 8080 (HTTP, straight to `app:80`) or 52443
(HTTPS, to `caddy:443` and on to `app:80`) → PHP reads/writes the data directory
(`DATA_HOST_PATH`), caches and locks in `nextcloud-redis`, and stores metadata in
`nextcloud-db`. The `cron` container shares `nextcloud-html` and the data
directory with `app` and runs maintenance independently of web traffic.

---

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Podman | Tested on 5.7.1, **rootless**. Quadlet needs ≥ 4.4 (the units also use `Notify=healthy`, so stay on a recent 5.x). `podman info --format '{{.Host.Security.Rootless}}'` should print `true`. |
| `systemd --user` + Quadlet | The Quadlet generator (`/usr/libexec/podman/quadlet`). `systemctl` and `loginctl` must work for your user. Lingering (`loginctl enable-linger`) is enabled by `setup.sh` so the services start at boot. |
| `openssl` | **Required** on every `up`/`restart`/`restore`: generates and checks the self-signed TLS certificate. (Also generates the initial secrets, with `od` as fallback.) |
| `curl` | Used by `status` for the HTTPS probe; the HTTP readiness probe falls back to a Bash `/dev/tcp` request. |
| `smbclient` *(optional)* | Only for `tests/smb-live-test.sh`. |
| Internet on first run | Pulls the images and builds `localhost/nextcloud-caddy-brotli:2` once (xcaddy, needs docker.io and github.com). Afterwards everything is local. |
| ~5 GB free disk | Images are ~1.9 GB; the rest is for user data and the database. |
| Free ports | `8080/tcp` (`NEXTCLOUD_PORT`) and `52443/tcp+udp` (`NEXTCLOUD_HTTPS_PORT`). `setup.sh` fails early with a clear message if one is taken. |

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

That is the whole installation. Once the images are present and the Caddy image
is built, the first start takes roughly 25 seconds (Nextcloud's own installer
runs, the database schema is created, the hook applies the extra configuration);
a cold machine also pays for the image pulls and the one-off Caddy build.
Subsequent starts take a few seconds.

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
`http://192.168.1.139:8080`, or at `https://192.168.1.139:52443` for clients
that mandate HTTPS. For HTTPS, import `tls/site.crt` into the client/OS trust
store (or accept the self-signed certificate once).

---

## Repository layout

```
.
├── systemd/                         # Quadlet unit templates (*.in) — rendered by setup.sh
├── docker/caddy/Containerfile       # Caddy + Brotli, built once by setup.sh
├── Caddyfile                        # TLS terminator config
├── tests/smb-live-test.sh           # live SMB add/modify/remove test
├── tls/                             # generated self-signed site.crt + site.key; git-ignored
├── .run/                            # generated per-service env files (secrets); git-ignored
├── setup.sh                         # launcher + backup + restore + diagnostics
├── .env.example                     # documented template, safe to commit
├── .env                             # generated; secrets; mode 0600; git-ignored
├── .gitignore
├── README.md
├── AGENTS.md                        # notes for AI agents working in this repo
├── INVESTIGATION_REPORT.md          # historical HTTPS investigation (not maintained)
├── upstreams/GitHub.sh              # git remote helper
├── backups/                         # git-ignored; each backup dir is mode 0700
│   └── 20261018-211951/
│       ├── database.sql.gz          # consistent dump (--single-transaction)
│       ├── data.tar.gz              # user files
│       ├── config.tar.gz            # config/ — holds config.php + instanceid
│       ├── env.backup               # the .env that matches this dump
│       └── systemd.backup/
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
| `NEXTCLOUD_BIND` | `0.0.0.0` | Host address to bind **both** published ports (HTTP and HTTPS). `0.0.0.0` = whole LAN, `127.0.0.1` = this machine only, or a specific interface IP. There is no HTTP-only bind. Health probes use this address (`127.0.0.1` when it is `0.0.0.0`). |
| `NEXTCLOUD_PORT` | `8080` | Host-side plain-HTTP port. The container always serves 80 internally. |
| `NEXTCLOUD_HTTPS_PORT` | `52443` | Host-side HTTPS port (Caddy, TCP+UDP for HTTP/3). |
| `TRUSTED_PROXIES` | *(empty)* | Networks whose `X-Forwarded-*` headers Nextcloud trusts. Empty = the subnet Podman allocated to `nextcloud-net`. |
| `DATA_HOST_PATH` | `<project>/data` | Host directory holding all user files (bind-mounted at `/var/www/html/data`). Must be an **absolute** path; created if missing. |
| `NEXTCLOUD_TRUSTED_DOMAINS` | auto-detected | Space-separated host names/IPs Nextcloud will answer for. Anything else gets *Access through untrusted domain*. |
| `NEXTCLOUD_OVERWRITE_CLI_URL` | `http://<host>:8080` | Base URL for links generated outside a web request (e-mail, `occ` output, background jobs). Generated once at first run using the default port 8080; **edit it by hand if you change `NEXTCLOUD_PORT` later**. |

### Database

| Variable | Default | Meaning |
| --- | --- | --- |
| `DB_NAME` | `nextcloud` | Database name. |
| `DB_USER` | `nextcloud` | Database user. |
| `DB_PASSWORD` | generated | Database password for `DB_USER`. The placeholder `change-me` is refused. |
| `DB_ROOT_PASSWORD` | generated | MariaDB root password. The placeholder `change-me` is refused. |
| `DB_INNODB_BUFFER_POOL` | `512M` | InnoDB buffer pool. Rule of thumb: ~25 % of the RAM you are willing to give MariaDB. |

### First-run administrator

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXTCLOUD_ADMIN_USER` | `admin` | Created **only on the first install** (fresh `nextcloud-html` volume and empty data directory). |
| `NEXTCLOUD_ADMIN_PASSWORD` | generated | Same — first install only; the placeholder `change-me` is refused. Change it later with `./setup.sh occ user:resetpassword admin`. |
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
| `NEXTCLOUD_IMAGE`, `DB_IMAGE`, `REDIS_IMAGE`, `CADDY_IMAGE` | *(empty = built-in default)* | Image overrides. `app` and `cron` always share `NEXTCLOUD_IMAGE`. `CADDY_IMAGE` is a local tag built from `docker/caddy` and never pulled. |
| `HELPER_IMAGE` | `docker.io/library/alpine:3` | Throwaway image used by `backup`/`restore` for tar and wipe helpers. |
| `APP_RUN_USER`, `APP_UID`, `APP_GID` (same for `DB_` and `REDIS_`) | *(empty = read from the image)* | Override the service account name or numeric ids that `keep-id` maps onto your user. `APP_RUN_USER` is also the account `occ` runs as (default `www-data`). |
| `SMB_TEST_USER`, `SMB_TEST_PASSWORD`, `SMB_TEST_SHARE`, `SMB_TEST_HOST`, `NC_TEST_USER` | *(empty)* | Only for `tests/smb-live-test.sh`. |

`STARTUP_TIMEOUT` (seconds `up`/`restart`/`restore` wait for the web UI, default
`600`) is read from the **shell environment**, not from `.env`:
`STARTUP_TIMEOUT=900 ./setup.sh up`.

> **Changing the administrator password in `.env` after the first start has no
> effect.** It is read once, by the installer, on the first install.
> Use `./setup.sh occ user:resetpassword admin` instead.

---

## How the pieces fit together

### The five services

**`caddy`** — TLS terminator: HTTPS on `:443` (published as `52443`, TCP and UDP
for HTTP/3), Brotli/zstd/gzip, proxying to `nextcloud-app:80`. See
[Reverse proxy](#reverse-proxy-caddy). Its image is built locally from
`docker/caddy` and never pulled.

**`app`** — with `caddy`, one of the two services that publish a host port. Its
unit `Requires=` and orders itself `After=` `db` and `redis`, and those two use
`Notify=healthy`, so systemd does not even start `app` until MariaDB reports
`--innodb_initialized` and Redis answers `PING`. This is why the stack comes up
cleanly instead of racing its own database.

**`db`** — MariaDB 11 with the three settings Nextcloud's own documentation
recommends: `--transaction-isolation=READ-COMMITTED`, `--binlog-format=ROW`, and
an InnoDB buffer pool sized from `.env`. `--skip-name-resolve` is added because
reverse DNS on a private bridge is pure latency with no benefit.
`MARIADB_AUTO_UPGRADE=1` lets the image apply its own minor-version schema
upgrades on start, so pulling a newer `mariadb:11` does not strand you.

**`redis`** — see below.

**`cron`** — reuses the exact same image (one `image_of nextcloud` value in
`setup.sh`, overridable via `NEXTCLOUD_IMAGE` in `.env`), so `app` and `cron`
can never drift apart in version. Its unit sets
`Entrypoint=/cron.sh`, which the image ships: a busybox `crond` reading the
bundled `www-data` crontab, running `php -f /var/www/html/cron.php` every five
minutes. `crond` itself runs as container-root (`User=root`: busybox needs
`setgroups()` to switch to the job's account, and a non-root `crond` silently
never runs jobs); under `keep-id` that root is a host sub-uid that writes nothing,
and the jobs run as the web account, i.e. you. `crond` is PID 1 and
ignores signals, so the unit runs a tiny init (`RunInit=yes`) with
`StopSignal=SIGTERM` and `SuccessExitStatus=143`: stopping it takes well under a
second and is not reported as a failure.

### Volumes: what lives where

| Volume | Mount | Contents | Replaceable? |
| --- | --- | --- | --- |
| `nextcloud-html` | `/var/www/html` | Program files, `config/config.php`, apps, themes | Yes — re-populated from the image |
| **(bind mount)** | `/var/www/html/data` | **User files**, `appdata_*`, `nextcloud.log` | **No — back this up** |
| `nextcloud-db` | `/var/lib/mysql` | Metadata (users, shares, file cache) | No |
| `nextcloud-redis` | `/data` | Cache, locks, PHP sessions | Yes — disposable by design |
| `nextcloud-caddy-data` | `/data` (in `caddy`) | Caddy runtime state | Yes — disposable (kept by `restore`) |

The bind mount's host path is **`DATA_HOST_PATH` in `.env`** (default
`<project>/data`, created if missing). Change it, then run `./setup.sh restart`.
Because the services run as your user (see
[File ownership and SMB access](#file-ownership-and-smb-access)), that directory
is owned by you and can be shared over SMB/NFS without any permission tricks.

There is no separate `nextcloud-data` volume: backups and restores operate
directly on the host path.

### Redis: cache, file locking *and* PHP sessions

Setting `REDIS_HOST` (in `.run/app.env`, rendered from `.env` by `setup.sh`) is doing more than it looks like:

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
| `filesystem_check_changes=1` | The data directory is shared with the host (SMB), so folders are re-checked against the filesystem on every listing and external changes show up immediately instead of after `occ files:scan`. |
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
| `up` *(default)* | Create `.env` if missing, run preflight checks (including the TLS certificate), build the Caddy image if absent, render and install the systemd user units, remove leftover non-Quadlet containers, migrate file ownership if needed, start the services, wait for the web UI to report itself installed, print access URLs. Refuses placeholder secrets (`change-me`) and a relative `DATA_HOST_PATH`. |
| `install` | Only (re)generate the units and env files (also creates `.env`, builds the Caddy image, enables lingering); start nothing. |
| `down` | Stop the services. **Volumes and data are kept.** |
| `restart` | Re-render the units and restart. Use after editing `.env` or `systemd/*.in`. |
| `status` | Unit state (and restart counts), containers, volumes, **ownership audit**, and live HTTP/HTTPS health probes. |
| `logs [svc]` | Follow logs — all services (`journalctl --user`), or one of `app`, `db`, `redis`, `cron`, `caddy` (`podman logs -f`). |
| `occ ...` | Run an `occ` command inside the running app container as the app's web account (`APP_RUN_USER`, default `www-data`). stdin/TTY is allocated when run interactively, so prompts such as `user:add` work. |
| `creds` | Print the generated administrator user and password. |
| `backup` | Write a database dump plus data and config archives. Not quiesced (see [Backups](#backups)). A failed backup removes its partial directory. |
| `restore [d]` | Replace the current instance with a backup (newest **complete** one by default, or a timestamp / directory). Validates the archives first and asks for confirmation. |
| `destroy` | Remove containers, the four named volumes and the network, then verify they are gone. **Never deletes the host data directory.** Asks for confirmation. |
| `help` | Print the usage block. |

Aliases: `start` = `up`, `stop` = `down`, `ps` = `status`, `password` = `creds`.

**Preflight checks** run before anything is created and will stop you early if
something is wrong:

- Podman present; `systemd --user` and the Quadlet generator reachable; reports
  whether Podman is rootless (warns if rootful).
- `NEXTCLOUD_PORT` and `NEXTCLOUD_HTTPS_PORT` are valid TCP ports.
- Neither port is already held by another process — unless it is held by *our*
  stack, in which case that is fine.
- Secrets are not the `change-me` placeholder; `DATA_HOST_PATH` is absolute.
- The data directory exists (it is created) and is writable by you.
- All five hook subdirectories exist and the tuning script is executable.
- `backups/` exists.
- The self-TLS certificate in `tls/` exists and covers every current name/IP
  (generated otherwise).

**`up` also fails fast rather than waiting out its timeout**: if the app
container exits during startup, it prints the last 30 log lines and aborts. On a
clean timeout it prints 40 lines. You never get "it hung and I don't know why".

`up`, `restart` and `restore` also remove leftover **non-Quadlet** containers named
exactly `nextcloud-db`, `-redis`, `-app`, `-cron` or `-caddy` (for instance from an
old podman-compose setup; `podman rm -f --depend`), because they would collide with
the units' names and ports. Volumes and data are untouched.

Health probe detail: the probe asks `http://<bind>:<port>/status.php` (`<bind>` is
`NEXTCLOUD_BIND`, or `127.0.0.1` when that is `0.0.0.0`) and requires
`"installed": true`, not merely a TCP connection. A half-installed instance is
therefore not reported as ready. It uses `curl` when available and a Bash
`/dev/tcp` request otherwise.

### Everyday recipes

```bash
# Create a user
./setup.sh occ user:add alice

# Reset the administrator password
./setup.sh occ user:resetpassword admin

# Validate the instance
./setup.sh occ status

# Re-scan files after copying something into the data directory by hand
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
| `database.sql.gz` | `mariadb-dump --single-transaction --quick --routines --events` | Metadata. `--single-transaction` gives a transaction-consistent snapshot **without locking tables**, so a running instance keeps serving requests during the dump. |
| `data.tar.gz` | The whole data directory (`DATA_HOST_PATH`) | Irreplaceable user files. |
| `config.tar.gz` | `config/` from the `html` volume | **Holds `config.php`.** See below. |
| `env.backup` | A copy of `.env`, mode `0600` | The dump's tables belong to these credentials. |
| `systemd.backup/` | A copy of the unit templates | So you know what generated the data. |

### Why `config.php` is mandatory, not optional

`config.php` holds `instanceid`, `secret` and `passwordsalt`. **`instanceid` is
not stored in the database** on Nextcloud 35 — `occ config:system:get instanceid`
reads `config.php` alone, and a fresh install generates a *different* one.

So a database-only restore produces an **orphan instance**: the data directory is
named `appdata_<instanceid>`, the database references the old instance id, and
the new instance refuses to let anyone log in. This is why the backup set
includes `config.tar.gz` and why `restore` puts it back.

### Taking a backup safely

A backup is **not quiesced**: the database dump is a transaction snapshot, and the
data archive is taken *afterwards* from the live directory, so files changed in
between can be newer than the dump. That is fine for an idle home instance. If you
need exact consistency, put the instance into maintenance mode around the backup:

```bash
./setup.sh occ maintenance:mode --on
./setup.sh backup
./setup.sh occ maintenance:mode --off
```

If a backup fails part-way, its partial directory is removed, so `restore` with no
argument always picks the newest **complete** backup.

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

Before the prompt it **validates the backup**: `database.sql.gz`, `data.tar.gz`
and `config.tar.gz` must pass `gzip -t` and `tar -t`, and a bad or incomplete
backup is refused. The prompt shows the backup directory **and** the data
directory that will be emptied, and you must type `RESTORE`. This is a
**destructive, in-place** operation: the current files, database and `config.php`
are replaced.

### What it actually does, and why in that order

1. **Saves the current `.env`** as `.env.pre-restore.<timestamp>`, then copies
   **only the database and administrator credentials** (`DB_NAME`, `DB_USER`,
   `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `NEXTCLOUD_ADMIN_USER`,
   `NEXTCLOUD_ADMIN_PASSWORD`) from the backup's `env.backup` into `.env`. The
   dump's tables belong to those credentials, so restoring one without the other
   yields an instance that cannot reach its own database. Ports, bind address,
   `DATA_HOST_PATH`, images and the rest stay as configured on this machine.
2. **Stops the stack, removes the containers and the `nextcloud-html`,
   `nextcloud-db` and `nextcloud-redis` volumes** (`nextcloud-caddy-data` is kept),
   fixes ownership, and **empties the data directory** (a failure is fatal and
   emptiness is verified). Then it **starts all five units from scratch**. The
   installer refuses to create the admin account while that user's folder still
   exists, so the throwaway install needs an empty directory; the restore replaces
   its contents anyway.
3. **Waits for the database, then for the web UI.** On the fresh volumes this runs
   the image's own installer once and produces a *throwaway* instance.
4. **Stops `caddy`, `cron` and `app`** so nothing is writing while data is swapped.
   `db` and `redis` stay up.
5. **Drops and recreates the database**, then imports `database.sql.gz`.
6. **Restores the data directory** from `data.tar.gz`, as you
   (`--userns=keep-id`, `--no-same-owner`) — whatever owners the archive recorded,
   the files end up yours.
7. **Restores `config/`** into the `html` volume from `config.tar.gz`.
8. **Starts all five units again** and waits for the web UI.
9. **Verifies** by printing the restored `instanceid` and the number of user
   accounts — a quick sanity check that you got *your* instance back, not a
   blank one.

Step 3 looks wasteful, and it is deliberate: **Podman only copies the image's
contents into a named volume while that volume is still empty.** Restoring
`config/` into a never-populated `html` volume would give you a container with no
program files. So the volume has to be populated first, and then overwritten.

Restored files belong to you: the helper container runs as your user
(`--userns=keep-id`) and ignores the archive's recorded owners, so no `chown` pass
is needed.

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

The image is **pinned**: `app` and `cron` both use the single value returned by
`image_of nextcloud` in `setup.sh` (default `docker.io/library/nextcloud:35-apache`,
overridable with `NEXTCLOUD_IMAGE` in `.env`). Nothing upgrades unless you say so,
and the two services can never drift apart.

To move to a new major version:

```bash
./setup.sh backup                  # non-negotiable
# set NEXTCLOUD_IMAGE=docker.io/library/nextcloud:36-apache in .env
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
Either free the port or pick another (the same applies to
`NEXTCLOUD_HTTPS_PORT`, default `52443`):

```bash
# edit NEXTCLOUD_PORT in .env, then
./setup.sh restart
```

### `rm: can't remove '/var/www/html/data': Resource busy`

You are trying to wipe the data directory from a container started with
`--volumes-from`. `/var/www/html/data` is itself a mount point inside that
container, so the mount shadows the directory and it cannot be removed. Bind-mount
the host directory directly at a different path instead:

```bash
podman run --rm --userns=keep-id -v "$DATA_HOST_PATH:/target:Z" docker.io/library/alpine:3 \
    sh -c 'rm -rf /target/* /target/.[!.]*'
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

The data directory was restored but `config.php` was not, producing an orphan
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

- `0.0.0.0:8080/tcp` — the Nextcloud web UI over plain HTTP, reachable from
  anything that can route to this host on port 8080. On a typical home LAN that is
  the LAN only, because the router does not forward inbound port 8080.
- `0.0.0.0:52443/tcp+udp` — the same UI over HTTPS (Caddy, self-signed
  certificate; UDP carries HTTP/3). Same reasoning about the router.
- Nothing else. `nextcloud-db:3306` and `nextcloud-redis:6379` are *exposed
  inside the container* but **not published to the host** — the `podman ps`
  output shows plain `3306/tcp` with no host mapping. They are reachable only on
  the private `nextcloud-net` bridge.

**What is not**

- No public DNS record, no port forwarding, no publicly trusted certificate.
- No `/var/run/docker.sock` mount. (This is why the `all-in-one` image was
  abandoned — see [Cleanup](#cleanup-leftovers-from-earlier-attempts).)
- No rootful daemon: Podman runs rootless as your user.

**Honest limitations — read these**

1. **Plain HTTP on `:8080` sends credentials in cleartext; use HTTPS on
   `:52443` on anything but a trusted wired LAN.** The HTTPS certificate is
   self-signed, so it gives you encryption but not identity until you import
   `tls/site.crt` on your clients. `NEXTCLOUD_BIND` applies to **both** ports,
   so `NEXTCLOUD_BIND=127.0.0.1` makes HTTPS local-only too; there is no way to
   expose only HTTPS to the LAN without a host firewall rule on `8080`.
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

- Add a firewall rule restricting ports 8080 and 52443 to your LAN subnet.
- Block inbound `8080/tcp` from the LAN with a host firewall rule so only Caddy
  (HTTPS) is reachable (`NEXTCLOUD_BIND` cannot do this: it covers both ports).
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
  NAT'd by the Podman bridge network and appears to come from the host.
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
because it is not part of this stack:

```console
$ podman volume ls | grep -i nextcloud
nextcloud_aio_mastercontainer     # ← stale, from the AIO attempt
nextcloud-caddy-data              # ← ours
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

# Take a final backup, then remove containers, the four named volumes and the network
./setup.sh backup
./setup.sh destroy        # asks you to type DELETE; verifies everything is gone

# Optionally remove the images too (the Caddy one is a local build)
podman rmi docker.io/library/nextcloud:35-apache \
           docker.io/library/mariadb:11 \
           docker.io/library/redis:7-alpine \
           docker.io/library/alpine:3 \
           localhost/nextcloud-caddy-brotli:2 \
           docker.io/library/caddy:2 docker.io/library/caddy:2-builder

# Optionally remove the rendered units (destroy leaves them installed), the
# generated files, and lingering
rm -f ~/.config/containers/systemd/nextcloud*.{container,network}
systemctl --user daemon-reload
rm -rf .run tls
loginctl disable-linger "$USER"      # only if nothing else of yours needs it
```

`destroy` is guarded by a typed confirmation and is irreversible for the database
and `config.php`. The **user files in `DATA_HOST_PATH` are never deleted** — remove
that directory yourself if you want them gone. `backups/` on the host is **not**
touched either, which is exactly why `config.tar.gz` is in it.

---

## Design decisions and why

| Decision | Rationale |
| --- | --- |
| Plain `nextcloud:35-apache`, not `all-in-one` | AIO requires the Docker socket, which rootless Podman cannot provide. |
| `db` + `redis` + `app` + `cron` + `caddy` | The composition Nextcloud itself documents for a small instance (MariaDB for metadata, Redis for cache/locking/sessions, a dedicated cron container) plus a Caddy TLS front end. |
| Quadlet units, not compose | Each service is a `systemctl --user` unit rendered from `systemd/*.in`: boot-time start via lingering, real dependency ordering with `Notify=healthy`, no extra tooling. There is no `compose.yaml`. |
| `0.0.0.0:8080 → 80` | LAN-accessible by choice. The container serves plain HTTP on **80**; 8080 is only the host side. Getting this backwards was the original cause of "the connection is refused". |
| Redis configured by `REDIS_HOST`, not `occ` | The image's own fragments take precedence over `config.php`; setting it twice would leave a misleading shadowed value behind. |
| Hook sets only unmanaged keys | Same reason — everything the image manages is set through the environment. |
| `data` is a host bind mount | Irreplaceable user files are backed up independently from rebuildable program code, and can be shared (SMB) because they belong to your user. Safe because `/data/` is in `/upgrade.exclude`. |
| Explicit volume names | `backup`/`restore` mount volumes by name, so the names must not be derived from anything that can change. |
| One image definition (`image_of`) | `app` and `cron` cannot silently drift to different versions, and nothing upgrades without you asking. |
| `backup` includes `config.tar.gz` | `instanceid` lives only in `config.php`; a DB-only restore is an orphan instance that refuses logins. |
| `restore` is a subcommand, not a README recipe | A manual recipe drifts from reality; a subcommand is testable and was tested. |
| `restore` installs once, then overwrites | Podman populates a named volume from the image only while it is empty. |
| `--single-transaction` dump | Transaction-consistent DB snapshot without locking tables, so backups do not need downtime (the data tar is taken afterwards from the live directory; use maintenance mode if exact consistency matters). |
| Hex secrets from `openssl rand -hex 24` | No quoting or `pipefail` hazards when injected into `.env`; `od` fallback if `openssl` is absent. |
| `help` reads its own header comment | Never prints stale text after the usage block is edited. |
| `destroy` requires typing `DELETE` once | Destructive and irreversible; the confirmation exists for exactly one reason. |

---

## Verified state

This stack was exercised end-to-end rather than assumed to work. The observations
below (sizes, counts, ids, versions) are **as of 2026-10-19**; re-run the checks in
[AGENTS.md](AGENTS.md) to refresh them. As of that run:

- **Stack** — five `systemctl --user` services (`nextcloud-db`, `-redis`, `-app`,
  `-cron`, `-caddy`), all active, `Restart=always`, wired to `default.target`
  with lingering enabled; `app` publishes `0.0.0.0:8080->80/tcp`, `caddy`
  publishes `0.0.0.0:52443->443/tcp+udp`.
- **Ownership** — every process that writes files runs as host uid = your uid
  (only `cron`'s `crond` supervisor is a container-root sub-uid and writes nothing),
  and every file in the data directory and all four volumes is owned by you
  (audited with `find` / `podman unshare find`; see
  [File ownership and SMB access](#file-ownership-and-smb-access)).
- **SMB** — `tests/smb-live-test.sh`: 38/38 checks pass over the LAN address,
  also after a `destroy` → `restore` drill; the same test **fails** with
  `NT_STATUS_ACCESS_DENIED` against the old ownership (negative control).
- **Web (HTTP)** — `http://localhost:8080/status.php` →
  `{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2"}`.
- **HTTPS via Caddy** — `https://<name>:52443/` returns the login page (HTTP/2,
  ~18 KB, certificate verified against `tls/site.crt`) for `localhost`,
  `127.0.0.1`, `nezha`, `nezha.local` and the LAN IP. Nextcloud emits `https://`
  URLs because Caddy's `X-Forwarded-Proto` is trusted (`TRUSTED_PROXIES`, see
  [Reverse proxy](#reverse-proxy-caddy)). A WebDAV PUT/GET/DELETE round trip over
  HTTPS lands the file on the host data path, and JS assets are served `br`.
- **HTTP/3 (QUIC)** — `curl --http3-only https://localhost:52443/status.php`
  → `200`, `http_version=3`. UDP `52443` must be reachable (LAN-only).
- **Runtime caching** — resolved through Nextcloud's own `ICacheFactory`:
  local `APCu`, distributed and locking `Redis`, PHP session handler `redis`,
  with live `PHPREDIS_SESSION:*` keys present in Redis.
- **Hook** — `==> nextcloud-tuning: configuration applied` on every start;
  `maintenance_window_start=1` and `lost_password_link=disabled` present.
- **Background jobs** — `backgroundjobs_mode = cron`, `nextcloud-cron` logging
  `crond (busybox 1.37.0) started`.
- **Database** — healthcheck passing, 138 tables.
- **Backup** — produced `database.sql.gz` (240 KB), `data.tar.gz` (61 MB),
  `config.tar.gz` (36 KB), `env.backup`, `systemd.backup/`.
- **Destroy** — `echo DELETE | ./setup.sh destroy` removed all five containers,
  all four named volumes and `nextcloud-net` (the data directory is kept).
- **Restore** — from a completely destroyed state,
  `./setup.sh restore <timestamp>` came back up with the **same instance id**
  (`ocvhsvisemzq`), the `admin` account, `background:cron` applied, and
  `files:scan --all` reporting **5 folders / 64 files / 0 errors**. The data
  directory contains `appdata_ocvhsvisemzq`, matching the restored id.

Versions in this run: Nextcloud 35.0.2.2 (PHP 8.5.11), MariaDB 11.8.9,
Redis 7.4.9, Podman 5.7.1 (rootless), Caddy 2 (xcaddy + caddy-brotli),
on ALT Starterkit 11 (kernel 6.12.61).


---

## Reverse proxy (Caddy)

`caddy` terminates TLS on `:443` (published as `52443`) and proxies everything
to `nextcloud-app:80`. Three things make it work, and each one has failed before:

1. **Everything lives inside a site block.** In a Caddyfile, a directive at the
   top level (outside `{ … }` / `:443 { … }`) is parsed as a *site address*. A
   flat file starting with `auto_https off` makes Caddy match only
   `Host: auto_https` / `Host: off`; every real request then matches no route
   and gets an **empty HTTP 200** — the "blank page". Check what Caddy really
   understood with
   `podman run --rm --entrypoint caddy -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" --env-file .run/caddy.env localhost/nextcloud-caddy-brotli:2 adapt --config /etc/caddy/Caddyfile`.
2. **The certificate is mounted at the path the Caddyfile names.** `./tls` →
   `/etc/caddy/tls` (read-only). `./setup.sh up`/`restart` create it via
   `ensure_tls`.
3. **Nextcloud trusts the proxy.** `TRUSTED_PROXIES` defaults to the subnet Podman
   actually allocated to `nextcloud-net` (override it in `.env`); `setup.sh` writes
   it into `.run/app.env` as an environment variable on `app`; never use
   `occ` for it. `overwriteprotocol` is deliberately *not* set, so plain HTTP on
   `:8080` keeps working alongside HTTPS.

Nextcloud is served at the root (`https://<host>:52443/`), not under
`/nextcloud`.

---

## Running under systemd (`--user`)

`./setup.sh up` renders `systemd/*.in` into `~/.config/containers/systemd/`
(Podman Quadlet), and Podman's generator turns each file into a user service:

| Unit | Role | Ordering |
| --- | --- | --- |
| `nextcloud-network.service` | the `nextcloud-net` bridge | — |
| `nextcloud-db.service` | MariaDB | `Notify=healthy` |
| `nextcloud-redis.service` | Redis | `Notify=healthy` |
| `nextcloud-app.service` | Nextcloud (Apache + PHP) | `Requires=` db + redis |
| `nextcloud-cron.service` | background jobs | `Requires=` app |
| `nextcloud-caddy.service` | HTTPS / HTTP/3 front end | `Wants=` app |

All are `Restart=always` and `WantedBy=default.target`; `setup.sh` enables
*lingering* for your user, so they start at boot without anyone logging in.
Use the usual tools:

```bash
systemctl --user status nextcloud-app
systemctl --user restart nextcloud-db      # dependants follow
journalctl --user -u 'nextcloud-*' -f
./setup.sh status                          # summary incl. restart counters
```

**Nothing is hard-coded.** The unit files are templates. Host paths, ports,
image references, the host user, the subnet Nextcloud trusts as its proxy and the
uid/gid of every service account are filled in at install time from `.env`, the
running system or the images themselves. Secrets never enter the units: they go
to per-service env files in `.run/` (mode `0600`, git-ignored).

## File ownership and SMB access

**The problem this fixes.** Rootless Podman maps the uids in a container onto a
range of *sub-uids* of yours. By default Apache/PHP's `www-data` therefore wrote
every file as a host uid that is **not you** (e.g. `100032`). The data directory
was then readable but not writable by your login — and by Samba, which acts as
the user who authenticated — so SMB uploads, edits and deletes failed with
`NT_STATUS_ACCESS_DENIED`.

**The fix.** Each container uses `UserNS=keep-id:uid=<U>,gid=<G>`, which maps the
service account of that image (`<U>:<G>`) onto *the invoking user*. The services
run as that account, so files are created as you. `<U>:<G>` is **read from the
image** at install time (`id` inside it), never assumed. Override in `.env` only
if an image changes its account: `APP_RUN_USER`, `APP_UID`, `APP_GID`, and the
same for `DB_` and `REDIS_`.

- `db`, `redis` and `app` (Apache, PHP, hooks) run entirely unprivileged.
  `app` can do so because `redis-session.ini`, which the entrypoint rewrites on
  every start, is a host-owned file bind-mounted from `.run/`.
- `caddy` runs as container-root, which rootless Podman already maps to you.
- `cron` is the exception: its `crond` supervisor runs as container-root
  (`User=root`; busybox `crond` needs `setgroups()` and a non-root one silently
  never runs jobs). Under `keep-id` that root is a host sub-uid, but it writes
  nothing — the jobs it launches run as the web account, which is you.
  Every process that writes files, and every file, belongs to you.
- Stack files written by an older setup are migrated by `./setup.sh up`
  (`podman unshare chown -R`, using the ids `podman unshare id` reports — no
  literal ids), then audited by `./setup.sh status`.
- `backup`/`restore` helpers run as you too (`--userns=keep-id`), so restored
  files are yours whatever the archive recorded.
- `filesystem_check_changes=1` (set by the hook) makes files added over SMB show
  up in Nextcloud the moment a folder is listed.

To share the data over Samba, point a share at `DATA_HOST_PATH`, e.g.:

```ini
[Nextcloud]
   path = /your/DATA_HOST_PATH
   read only = No
```

## Testing

`tests/smb-live-test.sh [host]` is a **live** end-to-end test of the above. As the
Samba account it uploads, overwrites, renames and deletes files and directories
in the Nextcloud user's folder (including a 1 MiB binary and nested directories),
checks the on-disk owner of everything, confirms Nextcloud sees SMB's changes over
HTTPS/WebDAV, and does the reverse (Nextcloud creates, SMB modifies and deletes).
It cleans up after itself and exits non-zero on any failure.

Credentials are read from the environment or `.env` (never committed):

```
SMB_TEST_USER=...      SMB_TEST_PASSWORD=...      SMB_TEST_SHARE=Nextcloud
```
