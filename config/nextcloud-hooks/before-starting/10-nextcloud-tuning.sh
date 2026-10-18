#!/bin/sh
# ---------------------------------------------------------------------------
#  Nextcloud container hook: "before-starting"
#
#  The official image runs every executable *.sh in
#  /docker-entrypoint-hooks.d/before-starting/ on *every* container start,
#  after the entrypoint has finished installing or upgrading the instance.
#
#  This script only sets keys the image does NOT manage itself. The image
#  already ships env-driven config fragments that take precedence over
#  config.php, so writing those keys here would be pointless:
#
#    apcu.config.php   -> memcache.local = APCu            (always)
#    redis.config.php  -> memcache.distributed, memcache.locking and the
#                         whole redis{host,port,password} block
#                         (only when REDIS_HOST is set — see compose.yaml)
#
#  So the caching and locking story is "set REDIS_HOST in .env", not "add an
#  occ call here". Duplicating it would leave values in config.php that are
#  silently shadowed at runtime, and that would then become live nonsense the
#  day REDIS_HOST is removed.
#
#  Everything below is an idempotent `occ config:system:set`, so running this
#  a hundred times equals running it once. A failure aborts container startup
#  on purpose: a half-configured instance is worse than one that refuses to
#  start.
#
#  Mounted read-only from ./config/nextcloud-hooks — see compose.yaml.
# ---------------------------------------------------------------------------

set -eu

OCC="php /var/www/html/occ"

log() { echo "==> nextcloud-tuning: $*"; }

# --- guard: only touch a completed installation ----------------------------
# On the very first boot the entrypoint installs the instance before calling
# this hook, so this normally passes. On a broken install it prevents the hook
# from bailing out with a confusing occ error.
if [ ! -f /var/www/html/config/config.php ]; then
    log "config.php does not exist yet; nothing to configure"
    exit 0
fi

if ! $OCC status --output=json 2>/dev/null | grep -q '"installed": *true'; then
    log "instance is not installed yet; nothing to configure"
    exit 0
fi

# --- background jobs belong to the `cron` service, not to page loads -------
# Nextcloud's default mode is "ajax": it fires background jobs opportunistically
# during web requests. The `cron` service in compose.yaml runs cron.php every
# five minutes instead, so the instance must be told to stop doing it in-band.
# Stored as app config (core / backgroundjobs_mode), not system config.
$OCC background:cron

# --- housekeeping ----------------------------------------------------------
# Run heavy maintenance at 01:00 local time instead of on the hour, so nightly
# jobs do not compete with evening uploads.
$OCC config:system:set maintenance_window_start --type=integer --value='1'

# Base URL for links generated outside a web request (mail, occ, cron).
if [ -n "${NEXTCLOUD_OVERWRITE_CLI_URL:-}" ]; then
    $OCC config:system:set overwrite.cli.url --value="${NEXTCLOUD_OVERWRITE_CLI_URL}"
fi

# Phone numbers typed without a country prefix need a default region, otherwise
# Nextcloud warns on every profile save. Optional — left unset by default.
if [ -n "${DEFAULT_PHONE_REGION:-}" ]; then
    $OCC config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"
fi

# There is no mail server here, so the "forgot password" link would send mail
# into the void. Recover the admin password from .env instead.
$OCC config:system:set lost_password_link --value='disabled'

log "configuration applied"
