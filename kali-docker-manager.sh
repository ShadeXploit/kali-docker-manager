#!/usr/bin/env bash
set -euo pipefail

# Configuration
CONTAINER_NAME="kali-persistent"
IMAGE_NAME="kalilinux/kali-rolling"
VOLUME_NAME="kali-data"

print_help() {
  cat <<'EOF'
Usage: kali-docker-manager.sh [--install | --start | --delete-all | -h | --help]

Options:
  --install     Create persistent Kali container if not already installed.
  --start       Start existing container if needed, then attach.
  --delete-all  Remove container, volume, and image after confirmation.
  -h, --help    Show this help message.
EOF
}

error() {
  echo "Error: $*" >&2
  exit 1
}

ensure_docker_available() {
  if ! command -v docker >/dev/null 2>&1; then
    error "Docker CLI is not installed or not in PATH."
  fi
}

ensure_docker_running() {
  # Validate both Docker daemon reachability and systemd unit state where available.
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker; then
      error "Docker service is not active. Start it with: sudo systemctl start docker"
    fi
  fi

  if ! docker info >/dev/null 2>&1; then
    error "Docker daemon is not reachable. Ensure dockerd is running and your user has Docker access."
  fi
}

volume_exists() {
  docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1
}

container_exists() {
  docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

install_container() {
  ensure_docker_available
  ensure_docker_running

  # Create a named volume once; it stores /root to keep data persistent.
  if ! volume_exists; then
    echo "Creating Docker volume: $VOLUME_NAME"
    docker volume create "$VOLUME_NAME" >/dev/null
  else
    echo "Volume already exists: $VOLUME_NAME"
  fi

  if container_exists; then
    echo "Container '$CONTAINER_NAME' is already installed."
    exit 0
  fi

  echo "Pulling image: $IMAGE_NAME"
  docker pull "$IMAGE_NAME"

  # Run interactively so the user lands directly in Kali shell on first install.
  docker run -it \
    --name "$CONTAINER_NAME" \
    -v "$VOLUME_NAME:/root" \
    "$IMAGE_NAME"
}

start_container() {
  ensure_docker_available
  ensure_docker_running

  if ! container_exists; then
    error "Container '$CONTAINER_NAME' is not installed. Run with --install first."
  fi

  if container_running; then
    # Use exec for a fresh interactive shell; avoids TTY resume artifacts from attach.
    echo "Container '$CONTAINER_NAME' is already running. Opening a new shell..."
    docker exec -it "$CONTAINER_NAME" /bin/bash
  else
    # Start and attach in one step for cleaner terminal handoff.
    echo "Starting and attaching to container '$CONTAINER_NAME'..."
    docker start -ai "$CONTAINER_NAME"
  fi
}

delete_all() {
  ensure_docker_available
  ensure_docker_running

  read -r -p "This will permanently delete container, volume, and image. Continue? (y/n): " confirm
  case "$confirm" in
    y|Y)
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac

  if container_exists; then
    # Force removal ensures cleanup even if the container is still running.
    echo "Removing container (force): $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    echo "Container not found: $CONTAINER_NAME"
  fi

  if volume_exists; then
    # Force volume removal to avoid partial cleanup states.
    echo "Removing volume (force): $VOLUME_NAME"
    docker volume rm -f "$VOLUME_NAME" >/dev/null
  else
    echo "Volume not found: $VOLUME_NAME"
  fi

  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    # Force image removal so this environment is fully reset for this image tag.
    echo "Removing image (force): $IMAGE_NAME"
    docker image rm -f "$IMAGE_NAME" >/dev/null
  else
    echo "Image not found locally: $IMAGE_NAME"
  fi

  if container_exists || volume_exists || docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    error "Cleanup did not fully complete. One or more resources still exist."
  fi

  echo "Cleanup complete: Kali container, volume, and image were fully removed."
}

main() {
  if [[ $# -ne 1 ]]; then
    print_help
    exit 1
  fi

  case "$1" in
    --install)
      install_container
      ;;
    --start)
      start_container
      ;;
    --delete-all)
      delete_all
      ;;
    -h)
      print_help
      ;;
    --help)
      print_help
      ;;
    *)
      error "Invalid flag: $1
Use --help to see valid options."
      ;;
  esac
}

main "$@"
