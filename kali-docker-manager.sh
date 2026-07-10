#!/usr/bin/env bash
set -euo pipefail

# Configuration
CONTAINER_NAME="kali-persistent"
IMAGE_NAME="kalilinux/kali-rolling"
VOLUME_NAME="kali-data"
SYNC_IMAGE_NAME="kali-persistent-sync:latest"
LAN_SESSION_CONTAINER_NAME="kali-lan-session"

print_help() {
  cat <<'EOF'
Usage: kali-docker-manager.sh [--install | --start | --start-lan | --delete-all | -h | --help]

Options:
  --install     Create persistent Kali container if not already installed.
  --start       Start existing container if needed, then attach.
  --start-lan   Start a LAN-capable host-network Kali session.
  --delete-all  Remove container, volume, and image after confirmation.
  -h, --help    Show this help message.
EOF
}

error() {
  echo "Error: $*" >&2
  exit 1
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is already installed."
    return 0
  fi

  echo "Docker is not installed. Installing Docker and dependencies..."

  # Update package lists 
  echo "Updating package lists..."
  sudo pacman -Sy --noconfirm

  # Install Docker
  echo "Installing Docker..."
  sudo pacman -S --noconfirm docker

  # Start Docker service
  echo "Starting Docker service..."
  sudo systemctl start docker
  sudo systemctl enable docker

  # Add current user to docker group
  echo "Adding current user to docker group..."
  sudo usermod -aG docker "$USER"

  echo "Docker installation complete!"
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

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
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

lan_session_container_exists() {
  docker container inspect "$LAN_SESSION_CONTAINER_NAME" >/dev/null 2>&1
}

lan_session_container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$LAN_SESSION_CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

ensure_volume_exists() {
  # Create a named volume once; it stores /root to keep data persistent.
  if ! volume_exists; then
    echo "Creating Docker volume: $VOLUME_NAME"
    docker volume create "$VOLUME_NAME" >/dev/null
  else
    echo "Volume already exists: $VOLUME_NAME"
  fi
}

sync_managed_container_to_image() {
  if ! container_exists; then
    return 0
  fi

  if container_running; then
    echo "Stopping running container '$CONTAINER_NAME' before syncing..."
    docker stop "$CONTAINER_NAME" >/dev/null
  fi

  echo "Syncing '$CONTAINER_NAME' state to image: $SYNC_IMAGE_NAME"
  docker commit "$CONTAINER_NAME" "$SYNC_IMAGE_NAME" >/dev/null
}

recreate_managed_container_from_sync_image() {
  if ! image_exists "$SYNC_IMAGE_NAME"; then
    error "Cannot recreate managed container; sync image not found: $SYNC_IMAGE_NAME"
  fi

  if container_running; then
    docker stop "$CONTAINER_NAME" >/dev/null
  fi

  if container_exists; then
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  echo "Recreating managed container '$CONTAINER_NAME' from synced state..."
  docker create \
    --name "$CONTAINER_NAME" \
    -v "$VOLUME_NAME:/root" \
    "$SYNC_IMAGE_NAME" >/dev/null
}

install_container() {
  install_docker_if_needed
  ensure_docker_available
  
  # Refresh shell group membership if docker was just installed
  if ! docker info >/dev/null 2>&1; then
    exec newgrp docker
  fi
  
  ensure_docker_running

  ensure_volume_exists

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
  install_docker_if_needed
  ensure_docker_available
  
  # Refresh shell group membership if docker was just installed
  if ! docker info >/dev/null 2>&1; then
    exec newgrp docker
  fi
  
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

start_container_lan() {
  install_docker_if_needed
  ensure_docker_available

  # Refresh shell group membership if docker was just installed
  if ! docker info >/dev/null 2>&1; then
    exec newgrp docker
  fi

  ensure_docker_running

  ensure_volume_exists

  # Prevent stale LAN session name collisions from previous interrupted runs.
  if lan_session_container_running; then
    docker stop "$LAN_SESSION_CONTAINER_NAME" >/dev/null
  fi
  if lan_session_container_exists; then
    docker rm "$LAN_SESSION_CONTAINER_NAME" >/dev/null
  fi

  if container_exists; then
    sync_managed_container_to_image
  fi

  local source_image="$SYNC_IMAGE_NAME"
  if ! image_exists "$source_image"; then
    echo "Pulling image: $IMAGE_NAME"
    docker pull "$IMAGE_NAME"
    source_image="$IMAGE_NAME"
  fi

  echo "Starting LAN-capable Kali session (host network)..."
  set +e
  docker run -it \
    --name "$LAN_SESSION_CONTAINER_NAME" \
    --network host \
    --cap-add NET_RAW \
    --cap-add NET_ADMIN \
    -v "$VOLUME_NAME:/root" \
    "$source_image"
  local lan_exit_code=$?
  set -e

  if lan_session_container_exists; then
    echo "Syncing LAN session state to image: $SYNC_IMAGE_NAME"
    docker commit "$LAN_SESSION_CONTAINER_NAME" "$SYNC_IMAGE_NAME" >/dev/null
    docker rm "$LAN_SESSION_CONTAINER_NAME" >/dev/null
    recreate_managed_container_from_sync_image
  fi

  return "$lan_exit_code"
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

  if lan_session_container_exists; then
    # Remove stale LAN session container if it exists from interrupted runs.
    echo "Removing LAN session container (force): $LAN_SESSION_CONTAINER_NAME"
    docker rm -f "$LAN_SESSION_CONTAINER_NAME" >/dev/null
  else
    echo "LAN session container not found: $LAN_SESSION_CONTAINER_NAME"
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

  if image_exists "$SYNC_IMAGE_NAME"; then
    echo "Removing synced state image (force): $SYNC_IMAGE_NAME"
    docker image rm -f "$SYNC_IMAGE_NAME" >/dev/null
  else
    echo "Synced state image not found locally: $SYNC_IMAGE_NAME"
  fi

  if container_exists || lan_session_container_exists || volume_exists || docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 || image_exists "$SYNC_IMAGE_NAME"; then
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
    --start-lan)
      start_container_lan
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
