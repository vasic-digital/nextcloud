# Nextcloud All-in-One Setup

## Overview
This repository contains a `setup.sh` script that deploys Nextcloud All-in-One (AIO) via Docker. The script launches the official `nextcloud-releases/all-in-one:latest` container with specific configuration.

## Usage

### Basic setup
Run the setup script:

```bash
bash setup.sh
```

### What it does
- Launches a Docker container named `nextcloud-aio-nezha`
- Maps port 8080 on host to 8080 in container
- Sets environment variables:
  - `SKIP_DOMAIN_VALIDATION=true` — skips TLS domain validation
  - `APACHE_PORT=11000` — custom Apache port
  - `APACHE_IP_BINDING=127.0.0.1` — bind Apache to localhost only
- Mounts two volumes:
  - `nextcloud_aio_mastercontainer` → `/mnt/Nextcloud/Data` (persistent data)
  - `/var/run/docker.sock` → `/mnt/Nextcloud/Container:ro` (Docker API access)

## Configuration

Edit `setup.sh` to modify:
- Container name (`--name nextcloud-aio-nezha`)
- Published port (`--publish 8080:8080`)
- Environment variables (domain validation, Apache port, IP binding)
- Volume mounts (data directory, Docker socket path)

## Common Issues

### Container won't start
- Ensure Docker is running
- Check that port 8080 is not already in use
- Verify Docker socket `/var/run/docker.sock` exists and is accessible

### Accessing Nextcloud
- After container starts, open `http://localhost:8080` in a browser
- First-time setup will guide you through initial configuration

### Persistent data
- Data is stored in the `nextcloud_aio_mastercontainer` Docker volume
- To backup: inspect Docker volumes with `docker volume ls | grep nextcloud`
- To restore: reuse the same volume name or mount a new path to `/mnt/Nextcloud/Data`

## Development / Modifications

To add/change features:
1. Modify `setup.sh` with desired Docker options
2. Re-run `bash setup.sh`
3. Container will restart with new configuration (due to `--restart always`)

### Notes
- The `--init` flag ensures proper signal handling
- `--sig-proxy=false` disables signal proxying (needed for some environments)
- `--restart always` ensures the container auto-restarts on reboot