# Kali Docker Persistent Manager

A Bash utility for managing a persistent Kali Linux Docker container on an Arch Linux host.

The script automates install, start/attach, and full cleanup workflows for a named Kali container with a persistent Docker volume.

## Script

- File: `kali-docker-manager.sh`
- Default container name: `kali-persistent`
- Default image: `kalilinux/kali-rolling`
- Default volume: `kali-data`

## Requirements

- Arch Linux (or another Linux distro with Docker and systemd)
- Docker installed and available in PATH
- Docker daemon running (`docker` service active)
- A user with permission to run Docker commands

## Make Executable

```bash
chmod +x ./kali-docker-manager.sh
```

## Usage

```bash
./kali-docker-manager.sh --install
./kali-docker-manager.sh --start
./kali-docker-manager.sh --start-lan
./kali-docker-manager.sh --delete-all
./kali-docker-manager.sh -h
./kali-docker-manager.sh --help
```

## Command Details

### --install

- Verifies Docker CLI and daemon availability.
- Verifies the `docker` systemd service is active.
- Creates the persistent volume (`kali-data`) if missing.
- Exits safely if container already exists.
- Pulls `kalilinux/kali-rolling` and starts an interactive container with `/root` mapped to the named volume.

### --start

- Verifies Docker CLI and daemon availability.
- Verifies the `docker` systemd service is active.
- Errors if the container is not installed.
- If running, attaches immediately.
- If stopped, starts then attaches.

### --start-lan

- Verifies Docker CLI and daemon availability.
- Creates the persistent volume (`kali-data`) if missing.
- Syncs the managed container state into a local snapshot image.
- Starts a LAN-capable host-network Kali session with `NET_RAW` and `NET_ADMIN`.
- On exit, syncs LAN-session filesystem changes back into the managed container state.
- Reuses the same persistent `/root` volume.

### --delete-all

- Requests interactive confirmation (y/n).
- Stops and removes the container if present.
- Removes the temporary LAN session container if present.
- Removes the persistent volume if present.
- Attempts to remove the Kali image and synced state image for complete cleanup.
- Prints completion status.

### -h / --help

- Prints command usage and available flags.

## Notes

- The script uses strict shell safety settings: `set -euo pipefail`.
- If Docker is not running, the script exits with clear instructions.
- Data persistence is provided through the Docker volume mounted at `/root`.
- LAN mode now syncs container filesystem changes so installs/config changes carry into normal `--start` sessions.

## Example Workflow

```bash
# First-time setup
./kali-docker-manager.sh --install

# Later sessions
./kali-docker-manager.sh --start

# LAN-capable session
./kali-docker-manager.sh --start-lan

# Full removal
./kali-docker-manager.sh --delete-all
```
