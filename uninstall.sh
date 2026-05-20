#!/bin/sh
# -----------------------------------------------------------------------------
# easy-ffmpeg uninstaller.
#
# Auto-detects which install mode is on this machine:
#   - CPU binary    → removes $INSTALL_DIR/easy-ffmpeg
#   - GPU wrapper   → removes $INSTALL_DIR/easy-ffmpeg, asks about the image
# Use --yes to skip both confirmations.
# -----------------------------------------------------------------------------
set -e

IMAGE="easy-ffmpeg:cuda"
LATEST_TAG="easy-ffmpeg:latest"

c_cyan()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

usage() {
  cat <<EOF
Usage: uninstall.sh [-y|--yes] [--help]

  -y, --yes   Skip confirmation prompts.
  --help      Show this help.

Removes the easy-ffmpeg binary/wrapper from \$INSTALL_DIR (or /usr/local/bin
when root, ~/.local/bin otherwise). For the GPU wrapper, also offers to
delete the easy-ffmpeg:cuda Docker image.
EOF
}

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) c_red "unknown option: $arg"; usage; exit 1 ;;
  esac
done

if [ -z "${INSTALL_DIR:-}" ]; then
  if [ "$(id -u)" = "0" ]; then
    INSTALL_DIR="/usr/local/bin"
  else
    INSTALL_DIR="${HOME}/.local/bin"
  fi
fi

TARGET="$INSTALL_DIR/easy-ffmpeg"

confirm() {
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  printf "%s [y/N] " "$1"
  read -r answer || answer=""
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Detect kind: GPU wrapper (shell script) vs CPU binary (ELF / Mach-O).
detect_kind() {
  if head -c 32 "$1" 2>/dev/null | grep -q '^#!'; then
    echo wrapper
  else
    echo binary
  fi
}

if [ ! -e "$TARGET" ]; then
  c_dim "easy-ffmpeg not found at $TARGET — nothing to uninstall."
  found="$(command -v easy-ffmpeg 2>/dev/null || true)"
  if [ -n "$found" ] && [ "$found" != "$TARGET" ]; then
    c_dim "(But 'easy-ffmpeg' resolves to $found — set INSTALL_DIR to that directory and re-run.)"
  fi
  exit 0
fi

KIND="$(detect_kind "$TARGET")"

c_cyan "easy-ffmpeg uninstall"
echo "  target: $TARGET ($KIND)"

IMAGE_PRESENT=0
if [ "$KIND" = wrapper ] && command -v docker >/dev/null 2>&1; then
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    IMAGE_PRESENT=1
    size_bytes="$(docker image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo 0)"
    size_mb=$(( size_bytes / 1024 / 1024 ))
    echo "  docker image: $IMAGE (~${size_mb} MB)"
  fi
fi
echo ""

if ! confirm "Remove the easy-ffmpeg command?"; then
  c_dim "Aborted."
  exit 0
fi

rm -f "$TARGET"
c_green "Removed $TARGET"

if [ "$IMAGE_PRESENT" = 1 ]; then
  if confirm "Also delete the Docker image ($IMAGE)?"; then
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
    docker rmi "$LATEST_TAG" >/dev/null 2>&1 || true
    c_green "Removed Docker image"
  else
    c_dim "Kept Docker image. Run 'docker rmi $IMAGE' manually to delete it later."
  fi
fi
