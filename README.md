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

> **Testing and evidence.** This repository ships a live test suite
> (`tests/run-all.sh`) that exercises the real units, containers, certificates and
> Nextcloud API and writes a checksummed evidence package. Documentation claims in
> this README are checked against the code by `tests/t11-docs.sh`. Start with
> [Testing and evidence](#testing-and-evidence) and [tests/README.md](tests/README.md).

---

## Table of contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Accessing the instance](#accessing-the-instance)
- [Repository layout](#repository-layout)
- [Configuration reference (`.env`)](#configuration-reference-env)
  - [Developer knobs](#developer-knobs)
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
- [Host tuning (optional)](#host-tuning-optional)
- [VPNs and container networking](#vpns-and-container-networking)
- [Cleanup: leftovers from earlier attempts](#cleanup-leftovers-from-earlier-attempts)
- [Uninstall](#uninstall)
- [FAQ](#faq)
- [Design decisions and why](#design-decisions-and-why)
- [Verified state](#verified-state)
- [Reverse proxy (Caddy)](#reverse-proxy-caddy)
- [Running under systemd (`--user`)](#running-under-systemd---user)
- [File ownership and SMB access](#file-ownership-and-smb-access)
- [Testing and evidence](#testing-and-evidence)

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
  backup` (optionally `--quiesce`) and `./setup.sh restore`.
- **Reversible.** `./setup.sh uninstall` removes the systemd units and generated
  files but keeps your volumes, data, `.env` and certificate; `destroy` removes the
  volumes. See [Uninstall](#uninstall).
- **Your files stay yours.** Every service runs through `UserNS=keep-id`, so what
  the stack writes is owned by your login user and a Samba share on the data
  directory stays writable. See [File ownership and SMB access](#file-ownership-and-smb-access).
- **Tested.** A live suite with a checksummed evidence package; see
  [Testing and evidence](#testing-and-evidence).

---

## Architecture

```text
                        your LAN (for example 192.168.1.0/24)
                                      │
        http://host:8080              │             https://host:52443
        plain HTTP (tcp)              │             tcp: HTTP/1.1 + HTTP/2, udp: HTTP/3
                                      ▼
┌────────────────────────────────────────────────────────────────────────────────────┐
│ host: rootless Podman; five `systemctl --user` Quadlet units (+ the network        │
│ unit), started at boot through lingering                                           │
│                                                                                    │
│   nextcloud-net  (private bridge; nextcloud-network.service)                       │
│   ┌──────────────────────────────────────────────────────────────────────────────┐ │
│   │ caddy  :443  TLS from tls/site.crt, br/zstd/gzip, /.well-known redirects     │ │
│   │    └── reverse_proxy ──►  app :80  (Apache + PHP, healthcheck)               │ │
│   │                             ├── db    :3306  MariaDB                         │ │
│   │                             └── redis :6379  cache, locks, sessions          │ │
│   │ cron   crond (container-root = a host sub-uid, under an init) -> cron.php    │ │
│   └──────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                    │
│ published:     app 80 -> NEXTCLOUD_PORT; caddy 443 tcp+udp -> HTTPS port           │
│ not published: db, redis, cron                                                     │
│ volumes:       nextcloud-html       /var/www/html   (program files, config)        │
│                nextcloud-db         /var/lib/mysql                                 │
│                nextcloud-redis      /data                                          │
│                nextcloud-caddy-data /data (in caddy)                               │
│ bind mount:    DATA_HOST_PATH -> /var/www/html/data  (user files, SMB-shared)      │
│ from the repo: Caddyfile, tls/ and config/nextcloud-hooks (read-only),             │
│                .run/*.env (one per service, mode 0600)                             │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Request path: browser → host port 8080 (HTTP, straight to `app:80`) or 52443
(HTTPS, to `caddy:443` and on to `app:80`) → PHP reads/writes the data directory
(`DATA_HOST_PATH`), caches and locks in `redis`, and stores metadata in `db`. The
`cron` container shares `nextcloud-html` and the data directory with `app` and runs
maintenance independently of web traffic.

The units and what they run as:

| Unit | Container | Image | Runs as (on the host) | Published |
| --- | --- | --- | --- | --- |
| `nextcloud-network.service` | *(the `nextcloud-net` bridge)* | — | — | — |
| `nextcloud-db.service` | `nextcloud-db` | `mariadb:11` | you (`mysql` mapped by `keep-id`) | no |
| `nextcloud-redis.service` | `nextcloud-redis` | `redis:7-alpine` | you (`redis` mapped by `keep-id`) | no |
| `nextcloud-app.service` | `nextcloud-app` | `nextcloud:35-apache` | you (`www-data` mapped by `keep-id`) | `NEXTCLOUD_PORT` → 80 |
| `nextcloud-cron.service` | `nextcloud-cron` | same image as `app` | `crond` as container-root, a host **sub-uid**, under an init; its jobs run as you | no |
| `nextcloud-caddy.service` | `nextcloud-caddy` | `localhost/nextcloud-caddy-brotli:2` | container-root, which maps to you | `NEXTCLOUD_HTTPS_PORT` → 443 tcp+udp |

`db`, `redis` and `app` are fully unprivileged. The one process that is not the
login user is cron's `crond` supervisor, which writes nothing; see
[File ownership and SMB access](#file-ownership-and-smb-access).

---

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Podman | Tested on 5.7.1, **rootless**. Quadlet needs ≥ 4.4 (the units also use `Notify=healthy`, so stay on a recent 5.x). `podman info --format '{{.Host.Security.Rootless}}'` should print `true`. |
| `systemd --user` + Quadlet | The Quadlet generator (`/usr/libexec/podman/quadlet`). `systemctl` and `loginctl` must work for your user. Lingering (`loginctl enable-linger`) is enabled by `setup.sh` so the services start at boot. |
| `openssl` | **Required** on every `up`/`restart`/`restore`: generates and checks the self-signed TLS certificate. (Also generates the initial secrets, with `od` as fallback.) |
| `curl` | Used by `status` for the HTTPS probe; the HTTP readiness probe falls back to a Bash `/dev/tcp` request. |
| `python3` | Required by the test runner (`tests/run-all.sh`) for the report. |
| `ss` *(optional)* | Used by the port preflight to say which process holds a port. |
| `smbclient` *(optional)* | Only for `tests/smb-live-test.sh` and `tests/t05-smb.sh`. |
| Internet on first run | Pulls the images and builds `localhost/nextcloud-caddy-brotli:2` once (xcaddy, needs docker.io and github.com). Afterwards everything is local. |
| ~5 GB free disk | Images were about 1.9 GB when measured on 2026-10-19; the rest is for user data and the database. |
| Free ports | `8080/tcp` (`NEXTCLOUD_PORT`) and `52443/tcp+udp` (`NEXTCLOUD_HTTPS_PORT`). `setup.sh` fails early with a clear message if one is taken. |

No `sudo` is required to install or run the stack; everything is a user service of your own account. The only things that need root are optional host-tuning sysctls (see [Host tuning](#host-tuning-optional)).

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

That is the whole installation. With the images present and the Caddy image
built, the first start took about 25 seconds on the reference host (measured
2026-10-19: Nextcloud's own installer runs, the database schema is created, the hook
applies the extra configuration); a cold machine also pays for the image pulls and
the one-off Caddy build, and `STARTUP_TIMEOUT` (default 600 s) bounds the wait.
Subsequent starts are much quicker. `./setup.sh install` renders the units and
env files without starting anything; `./setup.sh status` shows what is running.

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

```text
.
├── systemd/                         # Quadlet unit templates (*.in) — rendered by setup.sh
│   ├── nextcloud-{db,redis,app,cron,caddy}.container.in
│   └── nextcloud.network.in
├── docker/caddy/Containerfile       # Caddy + Brotli, built once by setup.sh
├── Caddyfile                        # TLS terminator config (global block + :443 site block)
├── tests/                           # live test suite and its evidence tooling
│   ├── README.md                    # how to run it, what each module proves
│   ├── run-all.sh                   # runner: modules, evidence, MANIFEST.sha256
│   ├── lib.sh, report.py            # shared library; report generator
│   ├── t01-static.sh … t11-docs.sh  # the test modules
│   ├── smb-live-test.sh             # live SMB add/modify/remove test
│   ├── publish-evidence.sh          # copy a passing run to docs/evidence/
│   └── evidence/                    # generated runs; git-ignored
├── tls/                             # generated self-signed site.crt + site.key; git-ignored
├── .run/                            # generated per-service env files (secrets, 0600); git-ignored
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
│       ├── env.backup               # the .env that matches this dump (secrets!)
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

Rendered units live outside the repository, in
`~/.config/containers/systemd/` (`$XDG_CONFIG_HOME/containers/systemd/`); the
per-service env files live in `.run/`.

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

### Scheduling

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXTCLOUD_MAINTENANCE_WINDOW_START` | `1` | Hour of the day (0-23, **UTC**) at which Nextcloud runs its heavy nightly maintenance jobs. Passed to `app` and applied by the hook as `maintenance_window_start`. Default `1`, i.e. 01:00 UTC rather than on the hour in the evening. |

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
| `SMB_TEST_USER`, `SMB_TEST_PASSWORD` | *(empty)* | The host account Samba authenticates, for `tests/smb-live-test.sh` and `tests/t05-smb.sh`. Never committed; redacted from test evidence. Without them the SMB test is skipped. |
| `SMB_TEST_SHARE` | `Nextcloud` | Name of the Samba share that exports `DATA_HOST_PATH`. |
| `SMB_TEST_HOST` | *(empty = the LAN IP)* | SMB server to test against. |
| `NC_TEST_USER` | *(empty = `NEXTCLOUD_ADMIN_USER`)* | Nextcloud user whose files directory the SMB test uses. |

`STARTUP_TIMEOUT` (seconds `up`/`restart`/`restore` wait for the web UI, default
`600`) is read from the **shell environment**, not from `.env`:
`STARTUP_TIMEOUT=900 ./setup.sh up`.

Everything the stack needs is derived, not configured: the host user comes from
`id`, each service account's uid/gid from its image, the proxy subnet from the Podman
network, and the LAN address and timezone from the system. See
[Running under systemd](#running-under-systemd---user).

### Developer knobs

These environment variables are read by `setup.sh` itself (not from `.env`). They
exist so tests and maintainers can render and inspect the units in throw-away
directories without touching the live stack.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXTCLOUD_ENV_FILE` | `.env` | Configuration file to read instead of `.env`. |
| `NEXTCLOUD_RUN_DIR` | `.run` | Directory for the generated per-service env files (created mode `0700`). |
| `NEXTCLOUD_QUADLET_DIR` | `$XDG_CONFIG_HOME/containers/systemd` (else `~/.config/containers/systemd`) | Directory the unit templates are rendered into. |
| `NEXTCLOUD_NO_RELOAD` | *(unset)* | When non-empty, `render_units` and `uninstall` do not run `systemctl --user daemon-reload`. |
| `NO_COLOR` | *(unset)* | When set, output has no colour. |

`setup.sh` is **sourceable**: it only defines functions when sourced and runs
`main` only when executed, so tests can call a single function, for example
`NEXTCLOUD_ENV_FILE=/tmp/x.env bash -c 'source ./setup.sh; image_of nextcloud'`.
The constants are read once at source time, so set the variables before sourcing.

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
cleanly instead of racing its own database. **Every** service has a healthcheck and shows `healthy` in `podman ps`: `app` runs
`curl -fsS http://localhost/status.php` (every 30 s, 300 s start period for the first
install); `caddy` asks Caddy's own admin API (inside the container, port 2019), so it
is independent of the app; `cron` looks for a live `crond` process. `cron` `Requires=` `app`;
`caddy` only `Wants=` it, so a web restart does not stop TLS.

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
| `maintenance_window_start` | Value of `NEXTCLOUD_MAINTENANCE_WINDOW_START` (default `1`, a UTC hour): run heavy maintenance then, so nightly jobs do not compete with evening uploads. |
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
| `up` *(default)* | Create `.env` if missing, run preflight checks (including the TLS certificate), build the Caddy image if absent, render and install the systemd user units, remove leftover non-Quadlet containers, migrate file ownership if needed, start the services, wait for the web UI to report itself installed, print access URLs. Refuses placeholder secrets (`change-me`), a relative `DATA_HOST_PATH` and, on a fresh install, a non-empty data directory. Prints a **drift warning** if the configuration changed since the services were started. After the first install it removes the administrator credentials from the app environment (one extra restart of `app`). |
| `install` | Only (re)generate the units and env files (also creates `.env`, the data directory and the certificate, builds the Caddy image, enables lingering); start nothing. |
| `down` | Stop the services. **Volumes and data are kept.** |
| `restart` | Re-render the units and env files and restart everything. This is what applies a drift warning; use it after editing `.env` or `systemd/*.in`. |
| `status` | Unit state (active/enabled, restart counts) and linger, containers, volumes, an **ownership audit** (data directory and the four volumes), optional **host-tuning advice** (`vm.overcommit_memory`, `net.core.rmem_max`; applying needs root) and live HTTP/HTTPS probes. |
| `logs [svc]` | Follow logs — all services (`journalctl --user`), or one of `app`, `db`, `redis`, `cron`, `caddy` (`podman logs -f`). |
| `occ ...` | Run an `occ` command inside the running app container as the app's web account (`APP_RUN_USER`, default `www-data`). stdin/TTY is allocated when run interactively, so prompts such as `user:add` work. |
| `creds` | Print the generated administrator user and password (read from `.env`). |
| `backup [--quiesce]` | Write a database dump plus data and config archives under `backups/<timestamp>/`. With `--quiesce`, Nextcloud is in maintenance mode while the dump and data archive are taken (`config.php` is archived first), so database and files are captured in the same state; maintenance mode is always switched off again, also when the backup fails. A failed backup removes its partial directory. See [Backups](#backups). |
| `restore [d]` | Replace the current instance with a backup (newest **complete** one by default, or a timestamp / directory). Validates all archives first, asks you to type `RESTORE`, then rebuilds the instance. See [Restoring a backup](#restoring-a-backup). |
| `uninstall` | Stop the services and remove the rendered units and `.run/`. **Keeps the volumes, the data directory, `.env` and `tls/`**; `./setup.sh up` brings the same instance back. See [Uninstall](#uninstall). |
| `destroy` | Remove containers, the four named volumes and the network, then verify they are gone. **Never deletes the host data directory.** Asks you to type `DELETE`. |
| `help` | Print the usage block (the header comment of `setup.sh`). |

Aliases: `start` = `up`, `stop` = `down`, `ps` = `status`, `password` = `creds`.
`-h` and `--help` also print the usage.

**Preflight checks** run before anything is created and will stop you early if
something is wrong:

- Podman present; `systemd --user` and the Quadlet generator reachable; reports
  whether Podman is rootless (warns if rootful).
- `NEXTCLOUD_PORT` and `NEXTCLOUD_HTTPS_PORT` are valid TCP ports.
- Neither port is already held by another process — unless it is held by *our*
  stack, in which case that is fine.
- Secrets are not the `change-me` placeholder; `DATA_HOST_PATH` is absolute.
- The data directory exists (it is created) and is writable by you. If no
  Nextcloud instance exists yet (no `nextcloud-html` volume), the directory must be
  **empty**: the installer refuses to create the administrator while that user's
  folder already exists. The check fails immediately with a message that points at
  `./setup.sh restore` or at emptying/moving the directory.
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

**Drift warning.** `up` records a SHA-256 of the rendered units and the per-service
env files in `.run/.applied` each time it starts the services. If that hash no
longer matches (you edited `.env` or a template and re-ran `up`), it prints
`the configuration changed since the services were started; run ./setup.sh restart to apply it.`
and does not apply the change silently. `restart` re-renders, restarts and records the
new hash.

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
./setup.sh backup              # live backup
./setup.sh backup --quiesce    # maintenance mode on during the backup
```

Writes `backups/<YYYYmmdd-HHMMSS>/` (mode `0700`) containing:

| File | What it is | Why it is needed |
| --- | --- | --- |
| `database.sql.gz` | `mariadb-dump --single-transaction --quick --routines --events` | Metadata. `--single-transaction` gives a transaction-consistent snapshot **without locking tables**, so a running instance keeps serving requests during the dump. |
| `data.tar.gz` | The whole data directory (`DATA_HOST_PATH`) | Irreplaceable user files. |
| `config.tar.gz` | `config/` from the `html` volume | **Holds `config.php`.** See below. |
| `env.backup` | A copy of `.env`, mode `0600` | The dump's tables belong to these credentials. **It contains your secrets.** |
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

A plain `backup` is **not quiesced**: the database dump is a transaction snapshot,
and the data archive is taken *afterwards* from the live directory, so files changed
in between can be newer than the dump. That is fine for an idle home instance. When
you need the database and the files to describe exactly the same moment, use

```bash
./setup.sh backup --quiesce
```

It first archives `config.php`, **then** switches Nextcloud into maintenance mode
(`occ maintenance:mode --on`), and takes the dump and the data archive. The order
matters: Nextcloud keeps its maintenance flag inside `config.php`, so a `config.php`
archived after maintenance mode was switched on would restore into a stuck
maintenance mode. The command switches maintenance mode **off again on every exit
path**, including when the backup fails or is interrupted. The web UI answers
"maintenance" meanwhile. The same effect by hand, without the guarantee:

```bash
./setup.sh occ maintenance:mode --on
./setup.sh backup
./setup.sh occ maintenance:mode --off
```

If a backup fails part-way, its partial directory is removed, so `restore` with no
argument always picks the newest **complete** backup (one that has all four files:
`database.sql.gz`, `data.tar.gz`, `config.tar.gz`, `env.backup`).

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
8. **Starts all five units again**, waits for the web UI and **scrubs the install
   secrets**: the first-install administrator credentials are removed from the
   app environment again (one extra restart of `app`), so the running container never
   keeps the admin password (see [Security posture](#security-posture)). If the
   restored configuration has maintenance mode switched on, `restore` switches it
   off again (with a warning) so the instance does not come up stuck in maintenance.
9. **Verifies** by printing the restored `instanceid` and the number of user
   accounts — a quick sanity check that you got *your* instance back, not a
   blank one.

Step 3 looks wasteful, and it is deliberate: **Podman only copies the image's
contents into a named volume while that volume is still empty.** Restoring
`config/` into a never-populated `html` volume would give you a container with no
program files. So the volume has to be populated first, and then overwritten.

The prompt and every refusal come **before** anything destructive. A restore is
refused, with nothing changed, when an archive fails `gzip -t` or `tar -t`, when
`config.tar.gz` lacks `config/config.php`, when the set is incomplete, or when you do
not type `RESTORE`.

A related guard on the other side: `./setup.sh up` on a machine with **no** Nextcloud
instance yet (no `nextcloud-html` volume) refuses a non-empty data directory, because
the installer would fail on it; the message points you at `restore`. That is exactly
the state after `destroy`, which keeps your files.

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
- Wait for the maintenance window rather than fighting it: heavy jobs run at the
  UTC hour in `NEXTCLOUD_MAINTENANCE_WINDOW_START` (default `1`).

---

## Troubleshooting

Each entry is symptom → cause → fix. First look at `./setup.sh status` (units,
containers, ownership, probes) and `./setup.sh logs`. `tests/run-all.sh
--non-destructive` pinpoints most of the problems below with a named check.

### SMB write fails with `NT_STATUS_ACCESS_DENIED`

**Cause:** files in the data directory belong to a sub-uid (for example `100032`), not
to the account Samba acts as. This is what the old setup produced, and it can reappear
if an older stack wrote into the directory.
**Fix:** run `./setup.sh status` and look at the *Ownership* section: it lists
entries not owned by you. Then `./setup.sh down && ./setup.sh up`; `up` migrates the
data directory and the volumes to your user with `podman unshare chown -R` and prints
`ownership migrated`. Make sure Samba's share points at `DATA_HOST_PATH` and that the
authenticating account is the user the stack runs as. Verify end to end with
`tests/smb-live-test.sh`.

### Blank white page over HTTPS (empty HTTP 200)

**Cause:** the `Caddyfile` lost its structure. Directives outside the `{ … }` global
block and the `:443 { … }` site block are parsed as a *site address*, so no route
matches and Caddy answers with an empty 200.
**Fix:** restore the layout (global block with `auto_https off`, then the `:443`
site block) and check what Caddy understood with `caddy adapt`, see
[Reverse proxy](#reverse-proxy-caddy). Also confirm `tls/site.crt` and `tls/site.key`
exist (`./setup.sh install` regenerates them) and run `./setup.sh restart`.

### Port already in use

**Symptom:** `up` stops during preflight with `port <N> is already in use by another
process` followed by `free it, or set NEXTCLOUD_PORT in .env to something else.`
**Cause:** another project or service holds `NEXTCLOUD_PORT` or `NEXTCLOUD_HTTPS_PORT`
(note that HTTPS needs both tcp and udp). **Fix:** find the owner and either stop it
or change the port in `.env`, then `./setup.sh up`:

```bash
ss -ltnup 'sport = :52443'      # replace with the port in the message
```

### Fresh install refused: the data directory is not empty

**Symptom:** `up` prints `no Nextcloud instance exists yet, but the data directory is
not empty`.
**Cause:** there is no `nextcloud-html` volume (first run, or after `destroy`), but
`DATA_HOST_PATH` already holds files; a fresh install must start from an empty
directory (otherwise the installer fails with "Login is invalid because files already
exist for this user").
**Fix:** to get the old instance back, `./setup.sh restore` a backup (it empties the
directory itself). To start from nothing, move or empty the directory, then
`./setup.sh up`. Nothing is deleted for you.

### Background jobs do not run (`cron` not running)

**Symptom:** the admin page warns that the last cron job ran a long time ago.
**Check:** `./setup.sh occ config:app:get core lastcron` (a unix timestamp that
should be less than about six minutes old), `systemctl --user status nextcloud-cron`
and `./setup.sh logs cron`.
**Cause:** the `cron` unit is down, or `crond` is running as a non-root user. Busybox
`crond` needs `setgroups()`; as non-root it logs `can't set groups` and silently never
runs a job. **Fix:** keep `User=root` in `systemd/nextcloud-cron.container.in` (under
`keep-id` that root is a host sub-uid that writes nothing), then `./setup.sh restart`.

### A service is not healthy (`app`, `caddy`, `cron`, `db`, `redis`)

All five services have healthchecks. **Check:** `podman ps` or
`podman inspect -f '{{.State.Health.Status}}' nextcloud-<svc>` and
`journalctl --user -u nextcloud-<svc> -n 100`. `app` has a 300 s start period, so
`starting` during the first install is normal. `caddy` unhealthy means Caddy itself
is not answering its admin API (check the Caddyfile with `caddy adapt`), not that the
app is down; `cron` unhealthy means no `crond` process is alive.
**Causes and fixes:** the database is not up yet (`nextcloud-db` must be `healthy`;
`journalctl --user -u nextcloud-db`); an *untrusted domain* answer (see below); the
entrypoint failed (`Permission denied` on `redis-session.ini` means the image moved
that file, fix the mount in the unit template; do **not** add `User=root`);
`needsDbUpgrade` after an image bump (`./setup.sh occ upgrade`).

### Units are `failed` (or `up` says a unit failed to start)

**Cause:** a unit crashed repeatedly and hit systemd's start limit, or was killed
behind systemd's back. **Fix:** read the reason (`systemctl --user status
nextcloud-<svc>`, `journalctl --user -u nextcloud-<svc>`), fix it, then
`systemctl --user reset-failed` and `./setup.sh up`. A stopped `nextcloud-cron` is not a
failure; `restart` and `down` handle it.

### "the configuration changed since the services were started"

**Cause:** you edited `.env` or a template and ran `up` (or edited files under
`.run/`). The running containers still use the old values. **Fix:**
`./setup.sh restart`. The warning disappears once the new hash is recorded.

### `restore` refuses to start

**Messages and meanings:** `<archive> is corrupt` / `is not a readable archive` (the
file is damaged, use another backup); `does not contain config/config.php` (an
old or hand-made backup without the instance identity); `is not a complete backup
set` (one of the four files is missing); `no complete backup found` (run
`./setup.sh backup` first); `aborted; nothing was restored` (you did not type
`RESTORE`); `could not empty <dir>` (files owned by another user; run
`./setup.sh down && ./setup.sh up` to migrate ownership, then retry). All of these happen
before the instance is touched.

### `up` cannot reach `systemd --user`

**Cause:** no user session bus, e.g. a `sudo`/`su` shell or a cron job without
`XDG_RUNTIME_DIR`. **Fix:** log in as the user that owns the stack (a plain `sudo` or `su` shell has no
user session) and retry; with lingering enabled the user manager runs even when you
are not logged in.

### "Access through untrusted domain"

You reached Nextcloud by a name or IP that is not in
`NEXTCLOUD_TRUSTED_DOMAINS`. This happens most often after the LAN IP changes.

```bash
./setup.sh occ config:system:get trusted_domains   # see what is allowed
# add the new host/IP to NEXTCLOUD_TRUSTED_DOMAINS in .env, then:
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

### Security model: secrets and processes

- **Secrets.** `.env` (mode `0600`) is the single source of truth. `setup.sh` derives
  one env file per service into `.run/` (directory `0700`, files `0600`) and each
  service receives only what it needs: the **database root password exists only in the
  `db` container**; `app` gets the database user's password, not root's; `cron` gets
  only the timezone; `caddy` only its upstream. No secret is written into a unit file.
- **Administrator credentials are short-lived in the environment.** They are put into
  the `app` environment *only until `config.php` says the instance is installed*.
  `scrub_install_secrets` then rewrites `app.env` without them and restarts `app`
  once, so the running container never keeps the admin password (check with
  `podman inspect nextcloud-app`). Later `up`/`restart` runs never put them back.
  `./setup.sh creds` still reads the password from `.env`.
- **Process model.** `db`, `redis` and `app` run unprivileged as your user (through
  `keep-id`). `caddy`'s container-root maps to your user. The one exception is
  `cron`: its `crond` runs as container-root (`User=root`), which under `keep-id` is a
  host **sub-uid**, under an init (`RunInit=yes`) so it stops in about 0.3 s; it
  writes nothing, and the jobs it launches run as the web account, i.e. you.
- **Containers are not privileged.** No `--privileged`, no added capabilities or
  devices, no host network/PID/IPC/user namespace, no `unconfined` options and no
  container-engine socket (verified by `tests/t10-security.sh`). Host bind mounts are
  limited to the data directory, `.run/redis-session.ini` and read-only `Caddyfile`,
  `tls/` and the hooks.
- **Discovery stays on HTTPS.** Caddy answers `/.well-known/caldav` and
  `/.well-known/carddav` with **relative** 301 redirects to `/remote.php/dav/`.
  Apache's own redirect is absolute and built from its plain-HTTP scheme, which would
  downgrade iOS and DAVx5 clients to `http://`.
- **Backups contain secrets** (`env.backup`) and user data; each directory is `0700`.

**If you want to go further**, in ascending order of effort:

- Add a firewall rule restricting ports 8080 and 52443 to your LAN subnet.
- Block inbound `8080/tcp` from the LAN with a host firewall rule so only Caddy
  (HTTPS) is reachable (`NEXTCLOUD_BIND` cannot do this: it covers both ports).
- Then, and only then, consider exposing it beyond the LAN — at which point you
  should also review Nextcloud's hardening guide.

---

## Host tuning (optional)

Two kernel settings improve behaviour but need root, so `setup.sh` never changes
them; `./setup.sh status` prints the exact commands when a value is below the
recommendation (and prints nothing when both are fine).

| Setting | Recommended | Why |
| --- | --- | --- |
| `vm.overcommit_memory` | `1` | Redis background saves fork the process; without overcommit a fork can fail under memory pressure. |
| `net.core.rmem_max` | at least `7340032` (the advice suggests `7500000`) | QUIC (HTTP/3) wants larger UDP receive buffers; Caddy logs a warning when they are small. |

Apply for the running system:

```bash
sudo sysctl vm.overcommit_memory=1
sudo sysctl net.core.rmem_max=7500000
```

Persist across reboots:

```bash
printf 'vm.overcommit_memory = 1\nnet.core.rmem_max = 7500000\n' | sudo tee /etc/sysctl.d/90-nextcloud.conf
sudo sysctl --system
```

Remove the file (and run `sudo sysctl --system`, or reboot) to undo the persistence.
The stack works without either setting.

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

Three commands, from least to most destructive:

| Command | Services | Units and `.run/` | Named volumes and network | Data directory | `.env`, `tls/`, `backups/` |
| --- | --- | --- | --- | --- | --- |
| `./setup.sh down` | stopped; the containers are **removed** when they stop (Quadlet runs them with `--rm`) | kept | kept (volumes, images) | kept | kept |
| `./setup.sh uninstall` | same as `down` | **removed** | kept; the Podman network object is left | kept | kept |
| `./setup.sh destroy` | same as `down` | kept | **removed**, including the network | kept | kept |

`uninstall` stops the services, removes the containers, deletes the rendered
`nextcloud*.container` and `nextcloud*.network` files from
`~/.config/containers/systemd/`, deletes `.run/` (the generated env files),
reloads systemd and clears failed states. Because the volumes, the data directory,
`.env` and `tls/` stay, `./setup.sh up` reinstalls the *same* instance (same
instance id, same files). `destroy` asks you to type `DELETE`, removes the four
named volumes and the network and **verifies** they are gone; it is irreversible for
the database and `config.php`, and it never deletes `DATA_HOST_PATH`.

### Removing everything

```bash
# 1. A final backup, then remove containers, the four named volumes and the network.
./setup.sh backup
./setup.sh destroy                  # type DELETE; verifies that everything is gone

# 2. Remove the units and the generated env files (.run/).
./setup.sh uninstall

# 3. Generated local files: the self-signed certificate and, if you want, the secrets.
rm -rf tls
# rm .env                           # also deletes the generated passwords

# 4. Optionally remove the images (the Caddy one is a local build).
podman rmi docker.io/library/nextcloud:35-apache \
           docker.io/library/mariadb:11 \
           docker.io/library/redis:7-alpine \
           docker.io/library/alpine:3 \
           localhost/nextcloud-caddy-brotli:2 \
           docker.io/library/caddy:2 docker.io/library/caddy:2-builder

# 5. Lingering, only if nothing else of yours needs it.
loginctl disable-linger "$USER"

# 6. Optional host tuning you added earlier.
sudo rm -f /etc/sysctl.d/90-nextcloud.conf
```

Your files in `DATA_HOST_PATH` are never deleted by any command: remove that
directory yourself if you want them gone. `backups/` is not touched either, which is
exactly why `config.tar.gz` is in it. Anything outside this repository (a Samba share
definition, firewall rules, other projects' containers) is not managed here.

---

## FAQ

**Do I need a domain or a public certificate?** No. The instance is LAN-only; HTTPS
uses a self-signed certificate. Exposing it to the internet is out of scope.

**The browser warns about the certificate.** Expected: it is self-signed. Import
`tls/site.crt` into the browser or OS trust store, or accept it once. The certificate
is regenerated automatically when a host name or the LAN IP changes.

**I edited `.env` and nothing changed.** Run `./setup.sh restart`. `up` warns about
unapplied changes but does not apply them. The initial administrator password is the
exception: it is read once at install; use `./setup.sh occ user:resetpassword`.

**Where are my files?** In `DATA_HOST_PATH` on the host (default `data/` in the
project), owned by you; share that directory over Samba or NFS if you like.

**Why does `cron` run as root when everything else is you?** Busybox `crond` must call
`setgroups()` to switch to the job's account and silently never runs jobs otherwise.
Under `keep-id` that root is a host sub-uid; it writes nothing, and the jobs run as the
web account, which is your user.

**Can I change the ports?** Yes: `NEXTCLOUD_PORT` and `NEXTCLOUD_HTTPS_PORT` in `.env`,
then `./setup.sh restart`. If you change `NEXTCLOUD_PORT`, also update
`NEXTCLOUD_OVERWRITE_CLI_URL`.

**How do I move to another machine?** `./setup.sh backup` here, copy `backups/<stamp>/`
and the `.env` of that backup to the new machine's project, then `./setup.sh restore
<stamp>` there (it brings the database and administrator credentials from the backup;
ports and paths stay as configured on the new machine).

**Is a backup safe to take while people use the instance?** A plain backup is a
consistent database snapshot plus a live copy of the files. Use `backup --quiesce` for
an exact point in time.

**Does `uninstall` delete my data?** No. It removes units and generated files only.

**Why is there no compose file?** The services are Podman Quadlet units run by
`systemd --user`, which gives boot-time start, health-gated ordering and restarts
without extra tooling.

**Can I run the tests on my real instance?** `tests/run-all.sh --non-destructive` is
safe; the full run restarts services, destroys and restores the instance, so take a
backup first. See [Testing and evidence](#testing-and-evidence).

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
| `uninstall` keeps volumes, data, `.env` and `tls/` | Removing the integration with systemd must not be able to lose data; `up` brings the same instance back. |
| Admin credentials only until installed | They are needed once, by the installer; leaving them in the container environment would expose them to `podman inspect` for the rest of its life. |
| Drift warning instead of silent apply | `up` must not restart a healthy stack behind your back, but must not let you believe an edit is live either. |
| `backup --quiesce` is opt-in | Maintenance mode interrupts users; it is only worth it when exact consistency matters. |
| `restore` copies only the DB and admin credentials | The dump belongs to those credentials; ports, bind address, data path and images belong to the machine. |
| Helper image is configurable (`HELPER_IMAGE`) | The backup/restore helpers need only `sh` and `tar`; offline hosts can point at a local image. |

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

For current evidence rather than this dated snapshot, run `tests/run-all.sh` and read
its `report.md` (see [Testing and evidence](#testing-and-evidence)).

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

4. **CalDAV/CardDAV discovery stays on https.** The Caddyfile answers
   `/.well-known/caldav` and `/.well-known/carddav` with relative `301` redirects
   (`redir`) to `/remote.php/dav/`. Apache's own `.htaccess` redirect would be
   absolute and built from its plain-HTTP scheme, downgrading clients to `http://`.

Nextcloud is served at the root (`https://<host>:52443/`), not under
`/nextcloud`.

### Ports, HTTPS and HTTP/3

- `app` publishes `NEXTCLOUD_BIND:NEXTCLOUD_PORT` → 80/tcp (plain HTTP).
  `caddy` publishes `NEXTCLOUD_BIND:NEXTCLOUD_HTTPS_PORT` → 443 on **both tcp and udp**:
  tcp carries HTTP/1.1 and HTTP/2, udp carries HTTP/3 (QUIC). Nothing else is
  published: `db`, `redis` and `cron` live on the private bridge only, and there is no
  port 80 listener in Caddy (`auto_https off`).
- The certificate in `tls/` is self-signed (RSA 2048, SHA-256, 825 days). `ensure_tls`
  regenerates it when it is missing, expires within 30 days or does not cover every
  current name: `localhost`, `127.0.0.1`, the host name, `<host>.local`, the LAN IP and
  every entry of `NEXTCLOUD_TRUSTED_DOMAINS`.
- Test each protocol from the host:

```bash
curl --cacert tls/site.crt https://localhost:52443/status.php
curl --cacert tls/site.crt --http2 -sI https://localhost:52443/login | head -1
curl --cacert tls/site.crt --http3-only https://localhost:52443/status.php   # needs an HTTP/3 curl
```

- QUIC likes larger UDP buffers; see [Host tuning](#host-tuning-optional). If clients
  cannot use UDP they silently fall back to HTTP/2 over tcp.

---

## Running under systemd (`--user`)

`./setup.sh up` renders `systemd/*.in` into `~/.config/containers/systemd/`
(Podman Quadlet), and Podman's generator turns each file into a user service:

| Unit | Role | Ordering and health |
| --- | --- | --- |
| `nextcloud-network.service` | the `nextcloud-net` bridge | one-shot, stays `active (exited)` |
| `nextcloud-db.service` | MariaDB, alias `db` | `Notify=healthy` (`healthcheck.sh --connect --innodb_initialized`) |
| `nextcloud-redis.service` | Redis, alias `redis` | `Notify=healthy` (`redis-cli ping`) |
| `nextcloud-app.service` | Nextcloud (Apache + PHP) | `Requires=` and `After=` db + redis; healthcheck `curl status.php` (300 s start period) |
| `nextcloud-cron.service` | background jobs | `Requires=` and `After=` app; `RunInit=yes`; healthy while a `crond` process exists |
| `nextcloud-caddy.service` | HTTPS / HTTP/3 front end | `Wants=` and `After=` app; `Pull=never`; healthcheck `wget` against Caddy's admin API (independent of the app) |

All are `Restart=always` and `WantedBy=default.target`; `setup.sh` enables
*lingering* for your user, so they start at boot without anyone logging in.
Use the usual tools:

```bash
systemctl --user status nextcloud-app
systemctl --user restart nextcloud-db      # dependants follow
journalctl --user -u 'nextcloud-*' -f
./setup.sh status                          # summary incl. restart counters
```

**Quadlet details.**

- Templates use `@TOKEN@` placeholders; `render_units` fills them in, refuses to
  write a unit with an unresolved placeholder and dry-runs Podman's Quadlet generator
  so a broken unit fails at `up` time, not at boot.
- Each container joins `nextcloud.network` (`nextcloud-net`); `db` and `redis` carry
  `NetworkAlias=` `db` / `redis` because `config.php` stores those host names.
- `app` and `cron` use `UserNS=keep-id:uid=<img uid>,gid=<img gid>`; `app` also sets
  `Sysctl=net.ipv4.ip_unprivileged_port_start=0` so non-root Apache can bind port 80
  inside its own network namespace (the host is unaffected).
- Per-service env files (`.run/db.env`, `app.env`, `cron.env`, `caddy.env`) are loaded
  with `EnvironmentFile=`; `.run/redis-session.ini` is the host-owned stand-in for the
  file the image's entrypoint rewrites.
- `TimeoutStartSec=900` for `app` (first install), `300` for `db`, `120` for `redis`.
- `cron` uses `RunInit=yes`, `StopSignal=SIGTERM` and `SuccessExitStatus=143`, so it
  stops in about 0.3 s and is not recorded as failed.
- **Drift detection.** `up` and `restart` store a SHA-256 of the rendered units and env
  files in `.run/.applied`; a later `up` that finds a different hash warns that
  `./setup.sh restart` is needed.
- `start_stack` clears stale failed states (`systemctl --user reset-failed`) before
  starting.

**Nothing is hard-coded.** The unit files are templates. Host paths, ports,
image references, the host user, the subnet Nextcloud trusts as its proxy and the
uid/gid of every service account are filled in at install time from `.env`, the
running system or the images themselves. Secrets never enter the units: they go
to per-service env files in `.run/` (mode `0600`, git-ignored). The
[developer knobs](#developer-knobs) let tests render into throw-away directories.

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

- `db`, `redis` and `app` (Apache, PHP, hooks) run entirely unprivileged as your user.
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

**How to see it.** `./setup.sh status` audits the data directory (entries not owned by
you) and the four volumes (`podman unshare find`); `podman top nextcloud-app huser user
pid args` shows the host uid of each process.

To share the data over Samba, point a share at `DATA_HOST_PATH`, e.g.:

```ini
[Nextcloud]
   path = /your/DATA_HOST_PATH
   read only = No
```

## Testing and evidence

The suite lives in `tests/` and is documented in [tests/README.md](tests/README.md).
It is **live**: it tests the running units, containers, certificates and Nextcloud
itself, not mocks.

```bash
tests/run-all.sh --non-destructive   # safe on a working instance
tests/run-all.sh                     # full: also restarts, destroys and restores the stack
tests/run-all.sh --list              # modules in run order
```

| Module | Proves |
| --- | --- |
| `t01-static.sh` | syntax, template/token consistency, no hard-coded ids or paths, `.env.example` coverage, git hygiene, secret scan, file modes |
| `t02-units.sh` | the Quadlet units, dependencies, health of all five services, restart policy, published ports, user namespaces |
| `t03-ownership.sh` | every process and file belongs to you (the documented cron exception), host and container write-through |
| `t04-https.sh` | Caddy: certificate and SANs, HTTP/2, HTTP/3, compression, no blank page, well-known redirects |
| `t05-smb.sh` | the SMB live test passes and fails against the old ownership (negative control) |
| `t06-nextcloud.sh` | WebDAV, OCS, Redis, MariaDB, hook settings, background jobs on the live instance |
| `t07-resilience.sh` | idempotent `up`, drift, self-healing, boot order, `uninstall`/reinstall, busy port (destructive) |
| `t08-backup-restore.sh` | `backup --quiesce`, refusal of bad backups, `restore`, `destroy` and restore from nothing (destructive) |
| `t09-dynamic.sh` | `setup.sh` against synthetic configuration: nothing is hard-coded |
| `t10-security.sh` | secrets handling, least privilege, exposure, hardening |
| `t11-docs.sh` | this documentation matches the code |

**The evidence package.** Each run writes `tests/evidence/<UTC time>/` (git-ignored,
`tests/evidence/latest` links to the newest) with `report.md` (verdict and every check),
`results.json` and `results.jsonl` (machine-readable, with the command, exit status and
redacted output of each check), `modules.jsonl`, `module-exit.tsv`, `environment.txt`
(host, tool versions, git commit, image digests, SHA-256 of the code under test),
`logs/`, `console/` and `MANIFEST.sha256`. Verify it has not been altered with
`cd tests/evidence/latest && sha256sum -c MANIFEST.sha256`. Secret values are redacted
everywhere. A passing run can be archived under `docs/evidence/` with
`tests/publish-evidence.sh`, which refuses a failing run, a broken manifest or any
secret in the evidence. The latest vetted run is committed under `docs/evidence/`.
Figures in this README come from such reports and carry their date.

**The SMB test.** `tests/smb-live-test.sh [host]` is a **live** end-to-end test of the
ownership fix. As the Samba account it uploads, overwrites, renames and deletes files
and directories in the Nextcloud user's folder (including a 1 MiB binary and nested
directories), checks the on-disk owner of everything, confirms Nextcloud sees SMB's
changes over HTTPS/WebDAV, and does the reverse (Nextcloud creates, SMB modifies and
deletes). It cleans up after itself and exits non-zero on any failure. Credentials are
read from the environment or `.env` (never committed); see `SMB_TEST_*` and
`NC_TEST_USER` in the [configuration reference](#configuration-reference-env):

```text
SMB_TEST_USER=...      SMB_TEST_PASSWORD=...      SMB_TEST_SHARE=Nextcloud
```

`tests/run-all.sh` is the runner; options are `--quick`, `--non-destructive`, `--only`,
`--skip`, `--list` and `--evidence-dir`. New behaviour needs a test: see
[tests/README.md](tests/README.md) for the library API and how to write a module.
